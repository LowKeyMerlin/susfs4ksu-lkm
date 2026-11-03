// SPDX-License-Identifier: GPL-2.0-only
/*
 * susfs_priority_filter.c: make chosen app uids look absent to getpriority(2), setpriority(2),
 * ioprio_get(2) and ioprio_set(2)
 *
 * With which = PRIO_USER (IOPRIO_WHO_USER for the ioprio pair) these calls answer ESRCH for a uid
 * with no process, so an app can walk the uid range and learn which apps are installed and running,
 * the root manager included. Upstream patches the four syscalls in kernel/sys.c and block/ioprio.c.
 * A module cannot, so the wrappers sit at the syscall table, like the stat and create families.
 *
 * For a hidden uid the wrapper calls the kernel's own entry with a copy of the registers in which
 * the id is one no user has. The kernel runs all its usual checks in its own order (a bad which or
 * ioprio is still EINVAL or EPERM) and ends in ESRCH. Reimplementing those checks would drift.
 *
 * Who is hidden from whom:
 *  - Only app uid callers (10000 and up) are filtered, like upstream.
 *  - A caller asking about its own uid is not filtered.
 *  - A caller KernelSU allows (the manager, an app granted root) sees the truth, as for every other
 *    hidden thing in this module. Upstream filters every app uid.
 *  - Hidden uids come from package names, looked up in /data/system/packages.list when the command
 *    arrives and again when the package list changes, since a reinstalled package gets another
 *    uid. The list names every installed package, also one with no directory under /data/data.
 *    A name that is not installed fails the command, so a typo is reported, but is skipped by
 *    the pass that follows a package change and picked up when installed. The event is packages.list
 *    being moved into /data/system, seen by a kprobe on d_move(), and it queues one delayed work
 *    item, so a burst is one pass and at most one pass runs a second. The pass runs with the
 *    credentials of whoever sent the list, which can read packages.list, since a kworker cannot
 *    read app data under SELinux (as measured in sus_path).
 *
 * Nothing runs unless a filtered syscall is made or the package list changes: no polling, timer
 * or thread. A lookup is one bit test.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/kprobes.h>
#include <linux/workqueue.h>
#include <linux/dcache.h>
#include <linux/rcupdate.h>
#include <linux/bitops.h>
#include <linux/bitmap.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/user_namespace.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/compat.h>
#include <linux/resource.h>
#include <linux/ioprio.h>
#include <asm/ptrace.h>
#include <asm/unistd.h>

#include "susfs.h"
#include "susfs_abi.h"
#include "susfs_fp_hook.h"
#include "susfs_log.h"
#include "ksu_allow_gate.h"

/* AArch32 table numbers (arch/arm/tools/syscall.tbl). The native ones come from __NR_*, the two
 * tables are numbered differently, see struct susfs_fp_hook. */
#define COMPAT_GETPRIORITY_NR	96
#define COMPAT_SETPRIORITY_NR	97
#define COMPAT_IOPRIO_SET_NR	314
#define COMPAT_IOPRIO_GET_NR	315

/* Every Android user has its own block of uids, the app id is the offset in it. */
#define PRIO_PER_USER_RANGE	100000
#define PRIO_NAME_MAX		255
#define PRIO_PKG_PATH		"/data/system/packages.list"
/* A line is a few hundred bytes, so this is tens of thousands of packages. */
#define PRIO_PKG_MAX		(4 * 1024 * 1024)

struct prio_bitmap {
	struct rcu_head rcu;
	DECLARE_BITMAP(bits, SUSFS_PRIORITY_UID_FILTER_UID_NUM);
};

static struct prio_bitmap __rcu *prio_bitmap;
/* Serialises writers. Readers (the syscalls) use RCU only. */
static DEFINE_MUTEX(prio_lock);

/* Under prio_lock: the list as sent, its sender's credentials, and a counter that tells a refresh
 * whether the list was replaced while it resolved. */
static char *prio_names;
static const struct cred *prio_cred;
static unsigned int prio_gen;

#define PRIO_PKG_LIST		"packages.list"
#define PRIO_PKG_DIR		"system"
#define PRIO_REFRESH_DELAY	HZ

static void prio_refresh(struct work_struct *work);
static DECLARE_DELAYED_WORK(prio_refresh_work, prio_refresh);

static susfs_syscall_fn_t prio_orig_getpriority;
static susfs_syscall_fn_t prio_orig_setpriority;
static susfs_syscall_fn_t prio_orig_ioprio_get;
static susfs_syscall_fn_t prio_orig_ioprio_set;
static susfs_syscall_fn_t prio_orig_compat_getpriority;
static susfs_syscall_fn_t prio_orig_compat_setpriority;
static susfs_syscall_fn_t prio_orig_compat_ioprio_get;
static susfs_syscall_fn_t prio_orig_compat_ioprio_set;

/* ---- which uids are hidden ---- */

static bool prio_valid_name(const char *name)
{
	size_t len = strlen(name);

	if (!len || len > PRIO_NAME_MAX)
		return false;
	/* A lone "." or ".." passes the character set below but is not a package name. */
	if (!strcmp(name, ".") || !strcmp(name, ".."))
		return false;
	for (; *name; name++) {
		char c = *name;

		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		    c == '.' || c == '_')
			continue;
		return false;
	}
	return true;
}

/*
 * The whole package list as one string. O_NOATIME keeps the read from touching the file's atime,
 * but the kernel refuses it with EPERM to a caller that neither owns the file nor holds
 * CAP_FOWNER. Such a caller can still read the list, so it is opened again without the flag.
 */
static char *prio_read_packages(void)
{
	struct file *fp;
	loff_t pos = 0, size;
	ssize_t got;
	char *buf;

	fp = filp_open(PRIO_PKG_PATH, O_RDONLY | O_NOATIME, 0);
	if (fp == ERR_PTR(-EPERM))
		fp = filp_open(PRIO_PKG_PATH, O_RDONLY, 0);
	if (IS_ERR(fp))
		return ERR_CAST(fp);

	size = i_size_read(file_inode(fp));
	if (size <= 0 || size > PRIO_PKG_MAX) {
		filp_close(fp, NULL);
		return ERR_PTR(-EFBIG);
	}
	buf = kvmalloc(size + 1, GFP_KERNEL);
	if (!buf) {
		filp_close(fp, NULL);
		return ERR_PTR(-ENOMEM);
	}
	got = kernel_read(fp, buf, size, &pos);
	filp_close(fp, NULL);
	if (got != size) {
		kvfree(buf);
		return ERR_PTR(got < 0 ? got : -EIO);
	}
	buf[size] = '\0';
	return buf;
}

/*
 * The uid of an installed package. A line of the list is "<package> <uid> <debuggable> ...", where
 * the uid is the app id. Only the part below the per-user range is kept.
 */
static int prio_lookup(const char *pkgs, const char *name, uid_t *uid)
{
	size_t len = strlen(name);
	const char *line = pkgs;

	while (*line) {
		const char *eol = strchrnul(line, '\n');

		if ((size_t)(eol - line) > len && !strncmp(line, name, len) &&
		    (line[len] == ' ' || line[len] == '\t')) {
			const char *num = line + len + 1;
			char digits[16];
			size_t n = 0;
			unsigned int val;

			while (num + n < eol && num[n] != ' ' && num[n] != '\t' &&
			       n < sizeof(digits) - 1)
				n++;
			memcpy(digits, num, n);
			digits[n] = '\0';
			if (kstrtouint(digits, 10, &val))
				return -EINVAL;
			*uid = val % PRIO_PER_USER_RANGE;
			if (*uid < SUSFS_PRIORITY_UID_FILTER_MIN_UID ||
			    *uid > SUSFS_PRIORITY_UID_FILTER_MAX_UID)
				return -EINVAL;
			return 0;
		}
		line = *eol ? eol + 1 : eol;
	}
	return -ENOENT;
}

/*
 * Set the bit of every package in the comma separated list, ignoring blanks and empty items. The
 * list is modified while it is split.
 *
 * A package with no uid fails the command, so a typo is reported. Upstream skips it, a deliberate
 * difference. On a refresh after a package change (lenient) a removed package is skipped and
 * picked up again when installed. A name that is not a package name, or a package list that
 * cannot be read, fails in both cases.
 */
static int prio_parse(char *list, unsigned long *bits, bool lenient)
{
	char *pkgs;
	char *item;

	pkgs = prio_read_packages();
	if (IS_ERR(pkgs)) {
		pr_warn("priority_filter: cannot read %s (%ld)\n", PRIO_PKG_PATH, PTR_ERR(pkgs));
		return PTR_ERR(pkgs);
	}

	while ((item = strsep(&list, ",")) != NULL) {
		uid_t uid;
		int rc;

		item = strim(item);
		if (!*item)
			continue;
		if (!prio_valid_name(item)) {
			pr_warn("priority_filter: '%s' is not a package name\n", item);
			kvfree(pkgs);
			return -EINVAL;
		}
		rc = prio_lookup(pkgs, item, &uid);
		if (rc) {
			if (lenient)
				continue;
			pr_warn("priority_filter: no uid for '%s' (%d)\n", item, rc);
			kvfree(pkgs);
			return rc;
		}
		set_bit(uid - SUSFS_PRIORITY_UID_FILTER_MIN_UID, bits);
		SUSFS_LOGI("priority_filter: '%s' is uid %u\n", item, uid);
	}
	kvfree(pkgs);
	return 0;
}

/* Swap in a new bitmap (may be NULL) and free the old one once no syscall can read it. */
static void prio_swap(struct prio_bitmap *bitmap)
{
	struct prio_bitmap *old;

	old = rcu_dereference_protected(prio_bitmap, lockdep_is_held(&prio_lock));
	rcu_assign_pointer(prio_bitmap, bitmap);
	if (old)
		kfree_rcu(old, rcu);
}

/* Replace the bitmap, list text and sender with a newly sent list. Takes ownership of bitmap and
 * names and its own reference on the credentials. */
static void prio_install(struct prio_bitmap *bitmap, char *names)
{
	const struct cred *old_cred;
	char *old_names;

	mutex_lock(&prio_lock);
	prio_swap(bitmap);
	old_names = prio_names;
	prio_names = names;
	old_cred = prio_cred;
	prio_cred = names ? get_cred(current_cred()) : NULL;
	prio_gen++;
	mutex_unlock(&prio_lock);

	kvfree(old_names);
	if (old_cred)
		put_cred(old_cred);
}

/* ---- the package list changed ---- */

/* Resolve the stored list again and publish it, unless a list was sent meanwhile: that one was
 * resolved after the change this pass is for. */
static void prio_refresh(struct work_struct *work)
{
	const struct cred *cred = NULL, *saved;
	struct prio_bitmap *bitmap;
	unsigned int gen = 0;
	char *list = NULL;
	size_t len;
	int err;

	mutex_lock(&prio_lock);
	if (prio_names && prio_cred) {
		len = strlen(prio_names);
		list = kvmalloc(len + 1, GFP_KERNEL);
		if (list) {
			memcpy(list, prio_names, len + 1);
			cred = get_cred(prio_cred);
			gen = prio_gen;
		}
	}
	mutex_unlock(&prio_lock);
	if (!list)
		return;

	bitmap = kzalloc(sizeof(*bitmap), GFP_KERNEL);
	if (bitmap) {
		/* One reference is ours and one is override_creds()'s, as in sus_path. */
		saved = override_creds(cred);
		err = prio_parse(list, bitmap->bits, true);
		revert_creds(saved);

		/* A list that cannot be read leaves the last good one in place. */
		mutex_lock(&prio_lock);
		if (!err && gen == prio_gen) {
			prio_swap(bitmap);
			bitmap = NULL;
		}
		mutex_unlock(&prio_lock);
		kfree(bitmap);
	}
	put_cred(cred);
	kvfree(list);
}

/*
 * The package manager writes packages.list into /data/system by moving a finished file over it,
 * the event KernelSU's observer waits for too. d_move(dentry, target) runs for every rename and
 * target already has the new name. Only names are read, the same file name in a directory other
 * than "system" is not the event.
 */
static int prio_pkg_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const struct dentry *target = (const struct dentry *)regs->regs[1];
	const struct dentry *dir;

	if (!target || target->d_name.len != sizeof(PRIO_PKG_LIST) - 1 ||
	    memcmp(target->d_name.name, PRIO_PKG_LIST, sizeof(PRIO_PKG_LIST) - 1))
		return 0;
	dir = READ_ONCE(target->d_parent);
	if (dir->d_name.len != sizeof(PRIO_PKG_DIR) - 1 ||
	    memcmp(dir->d_name.name, PRIO_PKG_DIR, sizeof(PRIO_PKG_DIR) - 1))
		return 0;
	/* A pass already waiting covers this one. */
	schedule_delayed_work(&prio_refresh_work, PRIO_REFRESH_DELAY);
	return 0;
}

static struct kprobe prio_pkg_kp = {
	.symbol_name = "d_move",
	.pre_handler = prio_pkg_pre,
};
static bool prio_pkg_armed;

/* ---- the check a syscall makes ---- */

/* Must the current caller not see this uid? The order keeps the common case cheap: non-apps and
 * callers asking about themselves never reach the bitmap, and KernelSU is asked only for a hidden
 * uid. */
static bool prio_hides(unsigned int who)
{
	const struct cred *cred = current_cred();
	struct prio_bitmap *bitmap;
	kuid_t target;
	uid_t app;
	bool hidden = false;

	if (!who || __kuid_val(cred->uid) < SUSFS_PRIORITY_UID_FILTER_MIN_UID)
		return false;
	target = make_kuid(cred->user_ns, who);
	if (!uid_valid(target) || uid_eq(target, cred->uid))
		return false;
	app = __kuid_val(target) % PRIO_PER_USER_RANGE;
	if (app < SUSFS_PRIORITY_UID_FILTER_MIN_UID || app > SUSFS_PRIORITY_UID_FILTER_MAX_UID)
		return false;

	rcu_read_lock();
	bitmap = rcu_dereference(prio_bitmap);
	if (bitmap)
		hidden = test_bit(app - SUSFS_PRIORITY_UID_FILTER_MIN_UID, bitmap->bits);
	rcu_read_unlock();

	return hidden && !susfs_ksu_allow_current();
}

/* __nocfi noinline: the call through orig is an indirect call into the kernel, which the build's
 * CFI call-site gate refuses if instrumented, see tools/cfi_sites.py. */
static __nocfi noinline long prio_dispatch(const struct pt_regs *regs, susfs_syscall_fn_t orig,
					   int user_which)
{
	struct pt_regs masked;

	if (!orig)
		return -ENOSYS;
	if ((int)regs->regs[0] != user_which || !prio_hides((u32)regs->regs[1]))
		return orig(regs);

	/* No user has this id, so the kernel's own entry ends in ESRCH. */
	masked = *regs;
	masked.regs[1] = (u32)-1;
	return orig(&masked);
}

/*
 * One wrapper serves both tables, so the original is picked by the caller's task type.
 *
 * Not a tail call: a wrapper that only branches has no frame, so with pointer authentication but
 * no BTI it gets neither paciasp nor bti c, and susfs_fp_install() refuses an entry without a
 * landing pad. Keeping the result live across the call forces a frame.
 */
#define PRIO_WRAPPER(sys, which)						\
static __nocfi noinline long prio_wrap_##sys(const struct pt_regs *regs)	\
{										\
	susfs_syscall_fn_t orig = is_compat_task() ?				\
		READ_ONCE(prio_orig_compat_##sys) : READ_ONCE(prio_orig_##sys);	\
	long ret = prio_dispatch(regs, orig, which);				\
										\
	__asm__ volatile("" : "+r"(ret));					\
	return ret;								\
}

PRIO_WRAPPER(getpriority, PRIO_USER)
PRIO_WRAPPER(setpriority, PRIO_USER)
PRIO_WRAPPER(ioprio_get, IOPRIO_WHO_USER)
PRIO_WRAPPER(ioprio_set, IOPRIO_WHO_USER)

static struct susfs_fp_hook prio_hooks[] = {
	{ .nr = __NR_getpriority, .nr_compat = COMPAT_GETPRIORITY_NR,
	  .name = "priority/getpriority", .sym = "__arm64_sys_getpriority",
	  .wrapper = prio_wrap_getpriority, .orig_slot = &prio_orig_getpriority,
	  .orig_slot_compat = &prio_orig_compat_getpriority },
	{ .nr = __NR_setpriority, .nr_compat = COMPAT_SETPRIORITY_NR,
	  .name = "priority/setpriority", .sym = "__arm64_sys_setpriority",
	  .wrapper = prio_wrap_setpriority, .orig_slot = &prio_orig_setpriority,
	  .orig_slot_compat = &prio_orig_compat_setpriority },
	{ .nr = __NR_ioprio_get, .nr_compat = COMPAT_IOPRIO_GET_NR,
	  .name = "priority/ioprio_get", .sym = "__arm64_sys_ioprio_get",
	  .wrapper = prio_wrap_ioprio_get, .orig_slot = &prio_orig_ioprio_get,
	  .orig_slot_compat = &prio_orig_compat_ioprio_get },
	{ .nr = __NR_ioprio_set, .nr_compat = COMPAT_IOPRIO_SET_NR,
	  .name = "priority/ioprio_set", .sym = "__arm64_sys_ioprio_set",
	  .wrapper = prio_wrap_ioprio_set, .orig_slot = &prio_orig_ioprio_set,
	  .orig_slot_compat = &prio_orig_compat_ioprio_set },
};

/* ---- the command ---- */

/* CMD_SUSFS_SET_PRIORITY_UID_FILTER: replace the filter with the packages in the list. */
void susfs_priority_filter_supercall(void __user **arg)
{
	struct st_susfs_priority_uid_filter __user *user = (void __user *)*arg;
	struct prio_bitmap *bitmap = NULL;
	char *names = NULL;
	char *work = NULL;
	char *keep = NULL;
	unsigned int hidden;
	long len;
	int err;

	/* The payload is 64 KiB, so read it as a string, not as the whole struct. */
	names = kvzalloc(SUSFS_APP_STR_BUF_SIZE + 1, GFP_KERNEL);
	if (!names) {
		err = -ENOMEM;
		goto out;
	}
	len = strncpy_from_user(names, (const char __user *)user->app_strings, SUSFS_APP_STR_BUF_SIZE);
	if (len < 0) {
		err = len;
		goto out;
	}
	if (len == 0 || len == SUSFS_APP_STR_BUF_SIZE) {
		/* Empty, or not terminated inside the buffer. */
		err = -EINVAL;
		goto out;
	}

	work = kvmalloc(len + 1, GFP_KERNEL);
	keep = kvmalloc(len + 1, GFP_KERNEL);
	bitmap = kzalloc(sizeof(*bitmap), GFP_KERNEL);
	if (!work || !keep || !bitmap) {
		err = -ENOMEM;
		goto out;
	}
	memcpy(work, names, len + 1);
	memcpy(keep, names, len + 1);

	err = prio_parse(work, bitmap->bits, false);
	if (err)
		goto out;
	err = 0;

	hidden = bitmap_weight(bitmap->bits, SUSFS_PRIORITY_UID_FILTER_UID_NUM);
	prio_install(bitmap, keep);
	bitmap = NULL;
	keep = NULL;
	SUSFS_LOGI("priority_filter: set, %u uids hidden\n", hidden);
out:
	kvfree(work);
	kvfree(keep);
	kvfree(names);
	kfree(bitmap);
	if (copy_to_user(&user->err, &err, sizeof(err)))
		pr_warn("priority_filter: copy_to_user failed\n");
}

/* ---- load and unload ---- */

/* All four or none. A filter covering three calls is worse than none: the fourth is a way around
 * it while the feature is advertised as working. */
int susfs_priority_filter_init(void)
{
	int i, rc;

	/* Without the package event the list goes stale when an app is reinstalled, which hides the
	 * wrong uid and shows the right one. */
	rc = register_kprobe(&prio_pkg_kp);
	if (rc) {
		pr_warn("priority_filter: register_kprobe(d_move) failed %d, the filter stays off\n", rc);
		return rc;
	}
	prio_pkg_armed = true;

	for (i = 0; i < (int)ARRAY_SIZE(prio_hooks); i++) {
		rc = susfs_fp_install(&prio_hooks[i]);
		if (rc) {
			pr_warn("priority_filter: %s not installed (%d), the filter stays off\n",
				prio_hooks[i].name, rc);
			goto undo;
		}
	}
	SUSFS_LOGI("priority_filter: armed on %u syscalls\n", (unsigned int)ARRAY_SIZE(prio_hooks));
	return 0;

undo:
	while (--i >= 0)
		susfs_fp_remove(&prio_hooks[i]);
	susfs_fp_drain();
	unregister_kprobe(&prio_pkg_kp);
	prio_pkg_armed = false;
	return rc;
}

void susfs_priority_filter_exit(void)
{
	bool armed = false;
	int i;

	/* Stop the event first so nothing queues a refresh, then wait for a queued or running one,
	 * which reads the list and publishes what is freed below. */
	if (prio_pkg_armed) {
		unregister_kprobe(&prio_pkg_kp);
		prio_pkg_armed = false;
	}
	cancel_delayed_work_sync(&prio_refresh_work);

	for (i = 0; i < (int)ARRAY_SIZE(prio_hooks); i++) {
		if (!prio_hooks[i].installed)
			continue;
		susfs_fp_remove(&prio_hooks[i]);
		armed = true;
	}
	if (armed)
		susfs_fp_drain();

	/* No syscall is in a wrapper now, so nothing reads the bitmap. A pending kfree_rcu() runs
	 * kernel code, not ours, and needs no barrier. */
	prio_install(NULL, NULL);
}
