// SPDX-License-Identifier: GPL-2.0-only
/*
 * susfs_uid_filter.c: the package-named uid sets behind the priority and sus_path filters
 *
 * Package names are looked up in /data/system/packages.list when the command arrives and again when
 * the package list changes, since a reinstalled package gets another uid. The list names every
 * installed package, also one with no directory under /data/data. A name that is not installed fails
 * the command for a strict filter, so a typo is reported, and is skipped for a lenient one. After a
 * package change a missing package is always skipped and picked up when installed.
 *
 * The event is packages.list being moved into /data/system, seen by a kprobe on d_move(). It queues
 * one delayed work item for all filters, so a burst is one pass and at most one pass runs a second.
 * The pass runs with the credentials of whoever sent each list, which can read packages.list, since
 * a kworker cannot read app data under SELinux (as measured in sus_path).
 *
 * Nothing runs unless the package list changes: no polling, timer or thread.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/kprobes.h>
#include <linux/workqueue.h>
#include <linux/dcache.h>
#include <linux/uidgid.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#include "susfs_uid_filter.h"
#include "susfs_log.h"

#define UF_NAME_MAX	255
#define UF_PKG_PATH	"/data/system/packages.list"
/* A line is a few hundred bytes, so this is tens of thousands of packages. */
#define UF_PKG_MAX	(4 * 1024 * 1024)
#define UF_PKG_LIST	"packages.list"
#define UF_PKG_DIR	"system"
#define UF_REFRESH_DELAY	HZ

/* Serialises attach, detach and the refresh pass, and guards the list of filters. */
static DEFINE_MUTEX(uf_reg_lock);
static LIST_HEAD(uf_filters);

static void uf_event_work(struct work_struct *work);
static DECLARE_DELAYED_WORK(uf_event, uf_event_work);

/* ---- which uids are in the set ---- */

static bool uf_valid_name(const char *name)
{
	size_t len = strlen(name);

	if (!len || len > UF_NAME_MAX)
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
static char *uf_read_packages(void)
{
	struct file *fp;
	loff_t pos = 0, size;
	ssize_t got;
	char *buf;

	fp = filp_open(UF_PKG_PATH, O_RDONLY | O_NOATIME, 0);
	if (fp == ERR_PTR(-EPERM))
		fp = filp_open(UF_PKG_PATH, O_RDONLY, 0);
	if (IS_ERR(fp))
		return ERR_CAST(fp);

	size = i_size_read(file_inode(fp));
	if (size <= 0 || size > UF_PKG_MAX) {
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
static int uf_lookup(const char *pkgs, const char *name, uid_t *uid)
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
			*uid = val % SUSFS_UID_PER_USER_RANGE;
			if (*uid < SUSFS_UID_FILTER_MIN_UID || *uid > SUSFS_UID_FILTER_MAX_UID)
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
 * A package with no uid fails the command unless the filter is lenient, so a typo is reported.
 * Upstream skips it, a deliberate difference for the priority filter. On a refresh after a package
 * change (lenient) a removed package is skipped and picked up again when installed. A name that is
 * not a package name, or a package list that cannot be read, fails in both cases.
 */
static int uf_parse(const struct susfs_uid_filter *f, char *list, unsigned long *bits, bool lenient)
{
	char *pkgs;
	char *item;

	pkgs = uf_read_packages();
	if (IS_ERR(pkgs)) {
		pr_warn("%s: cannot read %s (%ld)\n", f->name, UF_PKG_PATH, PTR_ERR(pkgs));
		return PTR_ERR(pkgs);
	}

	while ((item = strsep(&list, ",")) != NULL) {
		uid_t uid;
		int rc;

		item = strim(item);
		if (!*item)
			continue;
		if (!uf_valid_name(item)) {
			pr_warn("%s: '%s' is not a package name\n", f->name, item);
			kvfree(pkgs);
			return -EINVAL;
		}
		rc = uf_lookup(pkgs, item, &uid);
		if (rc) {
			if (lenient)
				continue;
			pr_warn("%s: no uid for '%s' (%d)\n", f->name, item, rc);
			kvfree(pkgs);
			return rc;
		}
		set_bit(uid - SUSFS_UID_FILTER_MIN_UID, bits);
		SUSFS_LOGI("%s: '%s' is uid %u\n", f->name, item, uid);
	}
	kvfree(pkgs);
	return 0;
}

/* Swap in a new bitmap (may be NULL) and free the old one once no reader can see it. */
static void uf_swap(struct susfs_uid_filter *f, struct susfs_uid_bitmap *bitmap)
{
	struct susfs_uid_bitmap *old;

	old = rcu_dereference_protected(f->bitmap, lockdep_is_held(&f->lock));
	rcu_assign_pointer(f->bitmap, bitmap);
	if (old)
		kfree_rcu(old, rcu);
}

/* Replace the bitmap, list text and sender with a newly sent list. Takes ownership of bitmap and
 * names and its own reference on the credentials. */
static void uf_install(struct susfs_uid_filter *f, struct susfs_uid_bitmap *bitmap, char *names)
{
	const struct cred *old_cred;
	char *old_names;

	mutex_lock(&f->lock);
	uf_swap(f, bitmap);
	old_names = f->names;
	f->names = names;
	old_cred = f->cred;
	f->cred = names ? get_cred(current_cred()) : NULL;
	f->gen++;
	mutex_unlock(&f->lock);

	kvfree(old_names);
	if (old_cred)
		put_cred(old_cred);
}

/* ---- the package list changed ---- */

/* Resolve the stored list again and publish it, unless a list was sent meanwhile: that one was
 * resolved after the change this pass is for. */
static void uf_refresh(struct susfs_uid_filter *f)
{
	const struct cred *cred = NULL, *saved;
	struct susfs_uid_bitmap *bitmap;
	unsigned int gen = 0;
	char *list = NULL;
	size_t len;
	int err;

	mutex_lock(&f->lock);
	if (f->names && f->cred) {
		len = strlen(f->names);
		list = kvmalloc(len + 1, GFP_KERNEL);
		if (list) {
			memcpy(list, f->names, len + 1);
			cred = get_cred(f->cred);
			gen = f->gen;
		}
	}
	mutex_unlock(&f->lock);
	if (!list)
		return;

	bitmap = kzalloc(sizeof(*bitmap), GFP_KERNEL);
	if (bitmap) {
		/* One reference is ours and one is override_creds()'s, as in sus_path. */
		saved = override_creds(cred);
		err = uf_parse(f, list, bitmap->bits, true);
		revert_creds(saved);

		/* A list that cannot be read leaves the last good one in place. */
		mutex_lock(&f->lock);
		if (!err && gen == f->gen) {
			uf_swap(f, bitmap);
			bitmap = NULL;
		}
		mutex_unlock(&f->lock);
		kfree(bitmap);
	}
	put_cred(cred);
	kvfree(list);
}

static void uf_event_work(struct work_struct *work)
{
	struct susfs_uid_filter *f;

	mutex_lock(&uf_reg_lock);
	list_for_each_entry(f, &uf_filters, node)
		uf_refresh(f);
	mutex_unlock(&uf_reg_lock);
}

/*
 * The package manager writes packages.list into /data/system by moving a finished file over it,
 * the event KernelSU's observer waits for too. d_move(dentry, target) runs for every rename and
 * target already has the new name. Only names are read, the same file name in a directory other
 * than "system" is not the event.
 */
static int uf_pkg_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const struct dentry *target = (const struct dentry *)regs->regs[1];
	const struct dentry *dir;

	if (!target || target->d_name.len != sizeof(UF_PKG_LIST) - 1 ||
	    memcmp(target->d_name.name, UF_PKG_LIST, sizeof(UF_PKG_LIST) - 1))
		return 0;
	dir = READ_ONCE(target->d_parent);
	if (dir->d_name.len != sizeof(UF_PKG_DIR) - 1 ||
	    memcmp(dir->d_name.name, UF_PKG_DIR, sizeof(UF_PKG_DIR) - 1))
		return 0;
	/* A pass already waiting covers this one. */
	schedule_delayed_work(&uf_event, UF_REFRESH_DELAY);
	return 0;
}

static struct kprobe uf_pkg_kp = {
	.symbol_name = "d_move",
	.pre_handler = uf_pkg_pre,
};

/* ---- the command ---- */

void susfs_uid_filter_supercall(struct susfs_uid_filter *f, const char __user *strings,
				int __user *errp)
{
	struct susfs_uid_bitmap *bitmap = NULL;
	char *names = NULL;
	char *work = NULL;
	char *keep = NULL;
	unsigned int count;
	long len;
	int err;

	if (!f->attached) {
		err = -ENODEV;
		goto out;
	}

	/* The payload is 64 KiB, so read it as a string, not as the whole struct. */
	names = kvzalloc(SUSFS_APP_STR_BUF_SIZE + 1, GFP_KERNEL);
	if (!names) {
		err = -ENOMEM;
		goto out;
	}
	len = strncpy_from_user(names, strings, SUSFS_APP_STR_BUF_SIZE);
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

	err = uf_parse(f, work, bitmap->bits, f->lenient);
	if (err)
		goto out;

	count = bitmap_weight(bitmap->bits, SUSFS_UID_FILTER_UID_NUM);
	uf_install(f, bitmap, keep);
	bitmap = NULL;
	keep = NULL;
	SUSFS_LOGI("%s: set, %u uids\n", f->name, count);
out:
	kvfree(work);
	kvfree(keep);
	kvfree(names);
	kfree(bitmap);
	if (copy_to_user(errp, &err, sizeof(err)))
		pr_warn("%s: copy_to_user failed\n", f->name);
}

/* ---- load and unload ---- */

int susfs_uid_filter_attach(struct susfs_uid_filter *f)
{
	int rc = 0;

	mutex_init(&f->lock);
	mutex_lock(&uf_reg_lock);
	if (list_empty(&uf_filters)) {
		rc = register_kprobe(&uf_pkg_kp);
		if (rc) {
			pr_warn("%s: register_kprobe(d_move) failed %d, the filter stays off\n",
				f->name, rc);
			goto out;
		}
	}
	list_add_tail(&f->node, &uf_filters);
	f->attached = true;
out:
	mutex_unlock(&uf_reg_lock);
	return rc;
}

void susfs_uid_filter_detach(struct susfs_uid_filter *f)
{
	bool last = false, was;

	mutex_lock(&uf_reg_lock);
	was = f->attached;
	if (was) {
		list_del(&f->node);
		f->attached = false;
		last = list_empty(&uf_filters);
	}
	mutex_unlock(&uf_reg_lock);

	/* Stop the event so nothing queues a refresh, then wait for a queued or running one, which
	 * reads the list and publishes what is freed below. A pass holds uf_reg_lock, so one that is
	 * running has finished with this filter before the lock was taken above. */
	if (last) {
		unregister_kprobe(&uf_pkg_kp);
		cancel_delayed_work_sync(&uf_event);
	}

	/* No reader is left, a pending kfree_rcu() runs kernel code, not ours, and needs no barrier. */
	if (was)
		uf_install(f, NULL, NULL);
}