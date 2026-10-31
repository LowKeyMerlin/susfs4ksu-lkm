// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_selinux_ctx.c - hide an admin-chosen list of SELinux context TYPES (e.g. "adbroot", a type
 * a custom ROM's own sepolicy adds) from the three places an app can ask "does this type exist in
 * the live policy": writing /sys/fs/selinux/context (sel_write_context), writing
 * /sys/fs/selinux/access (sel_write_access - what Java's SELinux.checkSELinuxAccess() and
 * libselinux's selinux_check_access() end up calling), and writing /proc/self/attr/current or one
 * of its siblings (selinux_setprocattr()) - which is also the write an app_zygote-forked process
 * does while probing a context's validity.
 *
 * Off by default, and inert until the admin writes at least one type into the list below: the
 * kernel has no idea what any particular ROM or module calls its own domains, so the three probes
 * stay unarmed at module load and arm themselves the moment the list stops being empty - nothing
 * here is keyed off a ROM name, a module name, or a hardcoded type string.
 *
 * Each hook takes over its target the way sus_map.c and susfs_hide_syms.c take over theirs: a
 * plain kprobe pre_handler decides BEFORE the real function body runs, and on a match sets the
 * return register and returns straight to the caller via susfs_probe_return() - the real function
 * body never executes.  That matters here for more than style: selinux_setprocattr(), for the
 * "current" attr, commits a NEW task SID via commit_creds() if let run - faking the error code
 * AFTER letting it run would leave a caller who thinks the write failed actually transitioned into
 * the context it meant to hide.  Skipping the body entirely is the only answer that cannot do that;
 * the other two hooked functions are pure queries (no process state changes), so skipping them
 * costs nothing beyond the answer this layer means to deny anyway.
 *
 * Applies only to the processes sus_path already hides from (susfs_is_current_proc_umounted_app()):
 * an app uid KernelSU would umount modules for, or an isolated uid.  A type an admin adds here is
 * presumed to be one no real root-side or system process ever needs to see resolve - this gate does
 * not know *why* a type is being probed, only *who* is asking, so a type su tooling itself
 * transitions into for real must not be added to this list.
 *
 * Interface: /proc/susfs_selinux_ctx, 0777 (see susfs_control_node_allowed() for why 0777 is not a
 * widened surface), root-only past that (susfs_control_visible()).
 *   write "add <type>"   add a context type to the hidden list (arms the probes on the first one)
 *   write "del <type>"   remove it (disarms the probes once the list is empty)
 *   write "clear"        remove every type (disarms the probes)
 *   read                 the list, whether the probes are armed, and per-probe hit counters
 */
#include <linux/module.h>
#include <linux/kernel.h>	/* ARRAY_SIZE() */
#include <linux/kprobes.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/atomic.h>
#include <linux/slab.h>
#include <linux/mm.h>		/* kvmalloc_array()/kvfree() for the list snapshot */
#include <linux/errno.h>

#include "susfs_log.h"
#include "susfs.h"
#include "susfs_kprobe.h"
#include "ksu_umount_gate.h"	/* susfs_is_current_proc_umounted_app() */
#include "ksu_allow_gate.h"	/* susfs_control_visible(): the control-node gate is su's own */

#define SUSFS_CTX_HIDE_MAX	32
#define SUSFS_CTX_HIDE_LEN	64	/* an SELinux type name is well under this on every policy seen */
#define SUSFS_CTX_CMDLINE	96

static char ctx_hide[SUSFS_CTX_HIDE_MAX][SUSFS_CTX_HIDE_LEN];
static int n_ctx_hide;
static DEFINE_SPINLOCK(ctx_hide_lock);

static atomic_t n_ctx_hits = ATOMIC_INIT(0);
static atomic_t n_access_hits = ATOMIC_INIT(0);
static atomic_t n_setattr_hits = ATOMIC_INIT(0);

/* The 3rd colon-separated field of a context string ("user:role:type:sensitivity[:categories]").
 * Bounds-checked against @len, which is NOT assumed to be NUL-terminated - both selinuxfs write
 * ops and selinux_setprocattr() hand this code a kernel buffer sized by the caller's write(2), not
 * a C string. */
static bool ctx_extract_type(const char *s, size_t len, const char **type, size_t *type_len)
{
	size_t i, field = 0, start = 0;

	for (i = 0; i <= len; i++) {
		if (i == len || s[i] == ':') {
			if (field == 2) {
				*type = s + start;
				*type_len = i - start;
				return true;
			}
			field++;
			start = i + 1;
		}
	}
	return false;
}

static bool ctx_type_hidden(const char *type, size_t type_len)
{
	unsigned long flags;
	bool hit = false;
	int i;

	if (!type_len || type_len >= SUSFS_CTX_HIDE_LEN)
		return false;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	for (i = 0; i < n_ctx_hide; i++) {
		if (strlen(ctx_hide[i]) == type_len && !memcmp(ctx_hide[i], type, type_len)) {
			hit = true;
			break;
		}
	}
	spin_unlock_irqrestore(&ctx_hide_lock, flags);
	return hit;
}

static bool ctx_hide_empty(void)
{
	unsigned long flags;
	bool empty;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	empty = (n_ctx_hide == 0);
	spin_unlock_irqrestore(&ctx_hide_lock, flags);
	return empty;
}

/* sel_write_context(file, buf, size): arm64 args put buf in x1, size in x2.  buf holds one bare
 * context string. */
static int ctx_context_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const char *buf = (const char *)regs->regs[1];
	size_t size = (size_t)regs->regs[2];
	const char *type;
	size_t type_len;

	if (ctx_hide_empty() || !buf || !size)
		return 0;
	if (!susfs_is_current_proc_umounted_app())
		return 0;
	if (!ctx_extract_type(buf, size, &type, &type_len) || !ctx_type_hidden(type, type_len))
		return 0;

	atomic_inc(&n_ctx_hits);
	regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
	susfs_probe_return(regs);
	return 1;
}

/* sel_write_access(file, buf, size): buf in x1, size in x2.  buf is "scontext tcontext tclass ...",
 * space-separated, and neither context contains a space. */
static int ctx_access_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const char *buf = (const char *)regs->regs[1];
	size_t size = (size_t)regs->regs[2];
	size_t i, tok_start;
	int tok = 0;

	if (ctx_hide_empty() || !buf || !size)
		return 0;
	if (!susfs_is_current_proc_umounted_app())
		return 0;

	for (i = 0, tok_start = 0; i <= size && tok < 2; i++) {
		const char *type;
		size_t type_len;

		if (i != size && buf[i] != ' ')
			continue;
		if (i > tok_start) {
			if (ctx_extract_type(buf + tok_start, i - tok_start, &type, &type_len) &&
			    ctx_type_hidden(type, type_len)) {
				atomic_inc(&n_access_hits);
				regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
				susfs_probe_return(regs);
				return 1;
			}
			tok++;
		}
		tok_start = i + 1;
	}
	return 0;
}

/* selinux_setprocattr(name, value, size): value in x1, size in x2.  value is the raw context
 * string a process is trying to adopt for one of attr/{current,exec,fscreate,keycreate,sockcreate},
 * again not guaranteed NUL-terminated. */
static int ctx_setattr_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const char *value = (const char *)regs->regs[1];
	size_t size = (size_t)regs->regs[2];
	const char *type;
	size_t type_len;

	if (ctx_hide_empty() || !value || !size)
		return 0;
	if (!susfs_is_current_proc_umounted_app())
		return 0;
	if (!ctx_extract_type(value, size, &type, &type_len) || !ctx_type_hidden(type, type_len))
		return 0;

	atomic_inc(&n_setattr_hits);
	regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
	susfs_probe_return(regs);
	return 1;
}

static struct kprobe kp_ctx_context = {
	.symbol_name = "sel_write_context",
	.pre_handler = ctx_context_pre,
};

static struct kprobe kp_ctx_access = {
	.symbol_name = "sel_write_access",
	.pre_handler = ctx_access_pre,
};

static struct kprobe kp_ctx_setattr = {
	.symbol_name = "selinux_setprocattr",
	.pre_handler = ctx_setattr_pre,
};

static struct kprobe *const ctx_probes[] = {
	&kp_ctx_context, &kp_ctx_access, &kp_ctx_setattr,
};

static bool ctx_probes_armed;

/* Serialises arm/disarm.  register_kprobe() answers -EINVAL once another task has resolved .addr,
 * and the failure branch below clears it - without this lock that disarms a probe that is LIVE,
 * the same hazard susfs_avc_spoof.c's avc_ctl_lock exists for.  Two tasks can reach "list went
 * from empty to one entry" at the same time (two /proc writers), and init reaches this too. */
static DEFINE_MUTEX(ctx_ctl_lock);

/* Set by susfs_selinux_ctx_exit() while holding the lock; registration refuses afterwards.  The
 * /proc node holds no module reference, so a write already inside ctx_proc_write() can reach this
 * during teardown. */
static bool ctx_exiting;

static int ctx_probes_register(void)
{
	int i, rc = 0;

	mutex_lock(&ctx_ctl_lock);
	if (ctx_exiting) {
		mutex_unlock(&ctx_ctl_lock);
		return -ENODEV;
	}
	if (ctx_probes_armed) {
		mutex_unlock(&ctx_ctl_lock);
		return 0;
	}
	for (i = 0; i < (int)ARRAY_SIZE(ctx_probes); i++) {
		rc = register_kprobe(ctx_probes[i]);
		if (rc) {
			/* The address register_kprobe() resolved is already in the struct even on
			 * failure - see susfs_kprobe.h - so the next retry needs it cleared. */
			susfs_kp_forget_addr(ctx_probes[i]);
			pr_warn("selinux_ctx: register_kprobe(%s) failed %d - context hiding is off\n",
				ctx_probes[i]->symbol_name, rc);
			break;
		}
	}
	if (rc) {
		while (--i >= 0) {
			unregister_kprobe(ctx_probes[i]);
			susfs_kp_forget_addr(ctx_probes[i]);
		}
		mutex_unlock(&ctx_ctl_lock);
		return rc;
	}
	ctx_probes_armed = true;
	mutex_unlock(&ctx_ctl_lock);
	SUSFS_LOGI("selinux_ctx: hooks installed (sel_write_context, sel_write_access, selinux_setprocattr)\n");
	return 0;
}

static void ctx_probes_unregister_locked(void)
{
	int i;

	if (!ctx_probes_armed)
		return;
	for (i = 0; i < (int)ARRAY_SIZE(ctx_probes); i++) {
		unregister_kprobe(ctx_probes[i]);
		susfs_kp_forget_addr(ctx_probes[i]);
	}
	ctx_probes_armed = false;
	SUSFS_LOGI("selinux_ctx: hooks removed\n");
}

static void ctx_probes_unregister(void)
{
	mutex_lock(&ctx_ctl_lock);
	ctx_probes_unregister_locked();
	mutex_unlock(&ctx_ctl_lock);
}

static int ctx_list_add(const char *type, size_t len)
{
	unsigned long flags;
	int rc = 0, n;

	if (!len || len >= SUSFS_CTX_HIDE_LEN)
		return -EINVAL;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	for (n = 0; n < n_ctx_hide; n++) {
		if (strlen(ctx_hide[n]) == len && !memcmp(ctx_hide[n], type, len)) {
			spin_unlock_irqrestore(&ctx_hide_lock, flags);
			return 0;	/* already there */
		}
	}
	if (n_ctx_hide >= SUSFS_CTX_HIDE_MAX) {
		rc = -ENOSPC;
	} else {
		memcpy(ctx_hide[n_ctx_hide], type, len);
		ctx_hide[n_ctx_hide][len] = '\0';
		n_ctx_hide++;
	}
	n = n_ctx_hide;
	spin_unlock_irqrestore(&ctx_hide_lock, flags);

	if (!rc && n == 1)
		rc = ctx_probes_register();
	return rc;
}

static int ctx_list_del(const char *type, size_t len)
{
	unsigned long flags;
	int i, n;
	bool found = false;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	for (i = 0; i < n_ctx_hide; i++) {
		if (strlen(ctx_hide[i]) != len || memcmp(ctx_hide[i], type, len))
			continue;
		memmove(&ctx_hide[i], &ctx_hide[i + 1],
			(size_t)(n_ctx_hide - i - 1) * SUSFS_CTX_HIDE_LEN);
		n_ctx_hide--;
		found = true;
		break;
	}
	n = n_ctx_hide;
	spin_unlock_irqrestore(&ctx_hide_lock, flags);

	if (!found)
		return -ENOENT;
	if (n == 0)
		ctx_probes_unregister();
	return 0;
}

static void ctx_list_clear(void)
{
	unsigned long flags;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	n_ctx_hide = 0;
	spin_unlock_irqrestore(&ctx_hide_lock, flags);
	ctx_probes_unregister();
}

/* The list copied out from under the lock before printing: seq_printf() can grow the seq buffer
 * with kvmalloc(GFP_KERNEL), which must not happen while a spinlock is held.  Off the stack for
 * the same reason sus_mount.c's keep-list snapshot is (SUSFS_CTX_HIDE_MAX * SUSFS_CTX_HIDE_LEN is
 * right at the -Wframe-larger-than boundary). */
static int ctx_proc_show(struct seq_file *m, void *v)
{
	char (*snap)[SUSFS_CTX_HIDE_LEN];
	unsigned long flags;
	int i, n;

	snap = kvmalloc_array(SUSFS_CTX_HIDE_MAX, SUSFS_CTX_HIDE_LEN, GFP_KERNEL);
	if (!snap)
		return -ENOMEM;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	n = n_ctx_hide;
	if (n)
		memcpy(snap, ctx_hide, (size_t)n * SUSFS_CTX_HIDE_LEN);
	spin_unlock_irqrestore(&ctx_hide_lock, flags);

	seq_printf(m, "armed=%d types=%d\n", ctx_probes_armed ? 1 : 0, n);
	for (i = 0; i < n; i++)
		seq_printf(m, "%s\n", snap[i]);
	seq_printf(m, "hits: context=%d access=%d setattr=%d\n",
		   atomic_read(&n_ctx_hits), atomic_read(&n_access_hits),
		   atomic_read(&n_setattr_hits));
	kvfree(snap);
	return 0;
}

static int ctx_proc_open(struct inode *inode, struct file *file)
{
	/* 0777 node + this check, like every other control node here: a restrictive mode would
	 * answer EACCES (advertising that the node exists) before sus_path could answer ENOENT. */
	if (!susfs_control_visible())
		return -ENOENT;
	return single_open(file, ctx_proc_show, NULL);
}

static ssize_t ctx_proc_write(struct file *file, const char __user *buf,
			      size_t len, loff_t *off)
{
	char cmd[SUSFS_CTX_CMDLINE];
	size_t trim;
	char *arg;
	int rc;

	if (!susfs_control_visible())
		return -ENOENT;
	if (len == 0)
		return 0;
	if (len >= sizeof(cmd))
		return -EINVAL;
	if (copy_from_user(cmd, buf, len))
		return -EFAULT;
	cmd[len] = '\0';

	trim = len;
	while (trim > 0 && (cmd[trim - 1] == '\n' || cmd[trim - 1] == '\r' || cmd[trim - 1] == ' '))
		trim--;
	cmd[trim] = '\0';

	if (!strcmp(cmd, "clear")) {
		ctx_list_clear();
		SUSFS_LOGI("selinux_ctx: list cleared\n");
		return (ssize_t)len;
	}
	if (!strncmp(cmd, "add ", 4) || !strncmp(cmd, "del ", 4)) {
		bool adding = (cmd[0] == 'a');

		arg = cmd + 4;
		while (*arg == ' ')
			arg++;
		if (!*arg)
			return -EINVAL;

		rc = adding ? ctx_list_add(arg, strlen(arg)) : ctx_list_del(arg, strlen(arg));
		if (rc)
			return rc;
		SUSFS_LOGI("selinux_ctx: %s %s -> %d type(s)\n", adding ? "add" : "del", arg,
			   n_ctx_hide);
		return (ssize_t)len;
	}

	return -EINVAL;
}

static const struct proc_ops ctx_proc_ops = {
	.proc_open = ctx_proc_open,
	.proc_read = seq_read,
	.proc_write = ctx_proc_write,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static struct proc_dir_entry *ctx_proc_entry;

int susfs_selinux_ctx_init(void)
{
	/* Unlike avc_spoof's switch, this feature has no supercall side: the /proc node is the only
	 * way the list is ever changed, the same as susfs_hide_mounts.c's and susfs_hide_syms.c's
	 * list nodes.  Without sus_path's LSM layer up (susfs_control_node_allowed() false) the
	 * list can never gain an entry, so the probes correctly stay unarmed for this boot. */
	if (susfs_control_node_allowed()) {
		ctx_proc_entry = proc_create("susfs_selinux_ctx", 0777, NULL, &ctx_proc_ops);
		if (!ctx_proc_entry)
			pr_warn("selinux_ctx: proc_create(susfs_selinux_ctx) failed\n");
		else
			SUSFS_LOGI("selinux_ctx: proc ready (/proc/susfs_selinux_ctx), off until a type is added\n");
	} else {
		SUSFS_LOGI("selinux_ctx: /proc node not created (expose_proc=%d lsm=%d)\n",
			(int)susfs_expose_proc, (int)sus_path_lsm_active());
	}
	return 0;
}

void susfs_selinux_ctx_exit(void)
{
	/* One critical section for "no more registrations" and the disarm, same reason
	 * susfs_avc_spoof_exit() needs one: a /proc write holds no module reference and can be
	 * inside ctx_proc_write() right now. */
	mutex_lock(&ctx_ctl_lock);
	ctx_exiting = true;
	ctx_probes_unregister_locked();
	mutex_unlock(&ctx_ctl_lock);

	if (ctx_proc_entry) {
		proc_remove(ctx_proc_entry);
		ctx_proc_entry = NULL;
	}
}
