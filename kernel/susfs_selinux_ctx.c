// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_selinux_ctx.c hides an admin-chosen list of SELinux context TYPES (for example "adbroot",
 * a type a custom ROM's sepolicy adds) from the two write paths an app uses to ask whether a type
 * exists in the live policy. Those paths are writing /sys/fs/selinux/{access,context,...} (behind
 * Java SELinux.checkSELinuxAccess() and libselinux selinux_check_access()) and writing
 * /proc/<pid>/attr/current and siblings (the setprocattr probe a forked app does).
 *
 * Off by default and inert until the admin adds a type. The kernel does not know what a given ROM
 * or module calls its domains, so the hooks stay unarmed at load and arm once the list is
 * non-empty. Nothing is keyed off a ROM name, a module name, or a hardcoded type.
 *
 * We hook the kernel's own entry points, not the SELinux callbacks (sel_write_access(),
 * selinux_setprocattr()). On a fork shipping selinux_hide those callbacks are swapped out for app
 * uids and never fire, but selinux_transaction_write() (the VFS .write for every selinuxfs
 * transaction file) and security_setprocattr() (the LSM dispatcher) run for every caller whatever
 * sits downstream. Measured on-device, for an app-uid selinuxfs write selinux_transaction_write()
 * fires while sel_write_access() does not, and for an app-uid attr write security_setprocattr()
 * fires while selinux_setprocattr() does not. So this layer keys off stock kernel symbols, not off
 * the presence or behaviour of selinux_hide.
 *
 * Both hooks read the context the caller submits (bounded by the write size, never assuming a NUL)
 * and, on a hit, make the write answer -EINVAL, exactly what an app gets for a context naming a
 * type the policy lacks, so a hidden type is indistinguishable from an absent one. The two paths
 * differ in where the error is faked, because they differ in whether the real body is safe to run.
 *
 * setprocattr "current" is a plain kprobe pre_handler (ctx_attr_pre). It fakes -EINVAL before the
 * body via susfs_probe_return(), because letting security_setprocattr() run would commit_creds() a
 * new task SID, so a caller told the write failed would in fact have transitioned into the context
 * it meant to hide. The body must not run, so timing cannot be matched there, but it is a
 * probe-only write and a fast reject costs nothing real.
 *
 * The selinuxfs query nodes (access/context/create/user/member, all pure computes) are a kretprobe
 * (ctx_txn_entry/ctx_txn_ret). The real write_op runs first, so the reject costs what a genuine
 * query for that type costs with no faster-than-absent timing tell, and the return handler then
 * drops the answer the body staged for a follow-up read (which would otherwise leak that the type
 * is valid) and rewrites the result to -EINVAL. When simple_transaction_set() cannot be resolved
 * on a KMI, the query node falls back to the pre-reject shape of setprocattr, leak-safe but without
 * the timing match.
 *
 * Applies only to the processes sus_path already hides from (susfs_is_current_proc_umounted_app()),
 * false for every uid < 10000, so policy load, init, adbd and root-side processes resolve the type
 * normally. Only an app that KernelSU would umount modules for is answered -EINVAL. A type added
 * here is presumed to be one no app legitimately needs, so do not add a type su tooling itself
 * transitions into.
 *
 * Why not duplicate selinux_hide: an app cannot read the policy blob or the class directory (MAC
 * denies untrusted_app, confirmed on-device and in detector reports). The only app-reachable
 * SELinux surface is this write-based validity oracle, which these two hooks cover whole.
 * selinux_hide's backup_sepolicy sanitises the policy READ, a surface apps do not have here, so it
 * is deliberately not duplicated.
 *
 * Interface: /proc/susfs_selinux_ctx, 0777, root-only past susfs_control_visible().
 *   write "add <type>"   add a type to the hidden list (arms the hooks on the first one)
 *   write "del <type>"   remove it (disarms once the list is empty)
 *   write "clear"        remove every type (disarms)
 *   read                 the list, the armed state, and per-hook hit counters
 */
#include <linux/module.h>
#include <linux/kernel.h>	/* ARRAY_SIZE() */
#include <linux/kprobes.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>	/* copy_from_user_nofault()/copy_from_kernel_nofault() */
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
#include "symbol_resolver.h"	/* find_kernel_symbol_exact(): simple_transaction_set is resolved, not linked */
#include "ksu_umount_gate.h"	/* susfs_is_current_proc_umounted_app() */
#include "ksu_allow_gate.h"	/* susfs_control_visible(): the control-node gate is su's own */

#define SUSFS_CTX_HIDE_MAX	32
#define SUSFS_CTX_HIDE_LEN	64	/* an SELinux type name is well under this on every policy seen */
#define SUSFS_CTX_CMDLINE	96
#define SUSFS_CTX_BUF		256	/* longest context query inspected, a real one is far shorter */

static char ctx_hide[SUSFS_CTX_HIDE_MAX][SUSFS_CTX_HIDE_LEN];
static int n_ctx_hide;
static DEFINE_SPINLOCK(ctx_hide_lock);

static atomic_t n_txn_hits = ATOMIC_INIT(0);	/* selinux_transaction_write redactions */
static atomic_t n_attr_hits = ATOMIC_INIT(0);	/* security_setprocattr redactions */

/* The 3rd colon-separated field of a context string ("user:role:type:sensitivity[:categories]").
 * Bounds-checked against @len, which is not assumed to be NUL-terminated. The write buffers handed
 * to both hooks are sized by the caller's write(2), not C strings. */
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

/* True if any space-separated token in @buf (length @len) is a context whose type is hidden. One
 * scan serves both hooks. A bare context ("u:r:adbroot:s0") is one token, an access query
 * ("scontext tcontext tclass perms...") is several, and the non-context tokens (a class number, a
 * permission name) have no 3rd colon field, so ctx_extract_type() rejects them for free. */
static bool ctx_buf_has_hidden_type(const char *buf, size_t len)
{
	size_t i, tok_start = 0;

	for (i = 0; i <= len; i++) {
		const char *type;
		size_t type_len;

		if (i != len && buf[i] != ' ')
			continue;
		if (i > tok_start &&
		    ctx_extract_type(buf + tok_start, i - tok_start, &type, &type_len) &&
		    ctx_type_hidden(type, type_len))
			return true;
		tok_start = i + 1;
	}
	return false;
}

/* selinux_transaction_write(file, buf, size, pos). arm64 puts the __user buffer in x1, size in x2.
 * One hook covers /sys/fs/selinux/access, /context and the other transaction nodes, since it is the
 * VFS .write for all of them, upstream of whatever handler the dispatch table currently points at. */
static int ctx_txn_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const void __user *ubuf = (const void __user *)regs->regs[1];
	size_t size = (size_t)regs->regs[2];
	char kbuf[SUSFS_CTX_BUF];
	size_t n;

	if (ctx_hide_empty() || !ubuf || !size)
		return 0;
	if (!susfs_is_current_proc_umounted_app())
		return 0;

	n = min(size, sizeof(kbuf));
	/* _nofault because a kprobe pre_handler runs in atomic context and must not fault. The page
	 * was just written by the caller, so this does not fault in practice. A fault means "could not
	 * inspect", and failing open there is correct, never deny a query this layer cannot read. */
	if (copy_from_user_nofault(kbuf, ubuf, n))
		return 0;
	if (!ctx_buf_has_hidden_type(kbuf, n))
		return 0;

	atomic_inc(&n_txn_hits);
	regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
	susfs_probe_return(regs);
	return 1;
}

/* security_setprocattr(lsm, name, value, size). The context value is x2 (a kernel buffer
 * memdup_user()'d by proc_pid_attr_write, so read with copy_from_kernel_nofault()) and size is x3.
 * The attr name (x1) is not inspected, since an app submitting a hidden type to any attr is probing
 * it and a bare context has the same shape whichever attr it targets. */
static int ctx_attr_pre(struct kprobe *kp, struct pt_regs *regs)
{
	const void *value = (const void *)regs->regs[2];
	size_t size = (size_t)regs->regs[3];
	char kbuf[SUSFS_CTX_BUF];
	size_t n;

	if (ctx_hide_empty() || !value || !size)
		return 0;
	if (!susfs_is_current_proc_umounted_app())
		return 0;

	n = min(size, sizeof(kbuf));
	if (copy_from_kernel_nofault(kbuf, value, n))
		return 0;
	if (!ctx_buf_has_hidden_type(kbuf, n))
		return 0;

	atomic_inc(&n_attr_hits);
	regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
	susfs_probe_return(regs);
	return 1;
}

/* Fallback for the query node, used only when simple_transaction_set() cannot be resolved, so the
 * body must be skipped to avoid staging a response that no resolved helper could then drop. Its
 * pre-reject is leak-safe but returns before the real parse, which is the timing tell the kretprobe
 * below removes. */
static struct kprobe kp_ctx_txn = {
	.symbol_name = "selinux_transaction_write",
	.pre_handler = ctx_txn_pre,
};

static struct kprobe kp_ctx_attr = {
	.symbol_name = "security_setprocattr",
	.pre_handler = ctx_attr_pre,
};

/* simple_transaction_set(file, 0) drops the answer the real selinuxfs write_op staged for a
 * follow-up read. Resolved at runtime rather than linked, since this module resolves vmlinux
 * symbols by name (symbol_resolver.c) rather than depending on which are exported on a given KMI.
 * NULL when the kernel does not name it to kallsyms, and then the query node uses the pre-reject
 * kp_ctx_txn, which never stages anything to drop. */
static void (*ctx_txn_set)(struct file *file, size_t n);
static bool ctx_txn_set_tried;

static void ctx_resolve_txn_set(void)
{
	if (ctx_txn_set_tried)
		return;
	ctx_txn_set_tried = true;
	ctx_txn_set = (void (*)(struct file *, size_t))
		find_kernel_symbol_exact("simple_transaction_set");
	if (!ctx_txn_set)
		pr_info("selinux_ctx: simple_transaction_set unresolved, query node uses the pre-reject path (leak-safe, timing-fast)\n");
}

/* Per-instance state for the query-node kretprobe: the struct file* captured on entry, so the
 * return handler can drop the staged response on it. */
struct ctx_txn_state {
	struct file *file;
};

/* selinux_transaction_write(file, buf, size, pos).  Same gate and scan as ctx_txn_pre(), but
 * instead of faking the error before the body it keeps the instance (returns 0) so the real
 * write_op runs first. The redaction in ctx_txn_ret() then costs what a genuine query for this
 * type costs, the timing a type the policy truly lacks would show, closing the gap a pre-handler
 * early return leaves open. Every call it leaves alone returns non-zero, which discards the
 * instance and skips the return trap, so a caller the gate excludes pays no more than this scan.
 * The query nodes are pure computes, so running their body has no side effect. The only
 * side-effecting node an app could reach, setprocattr, is a separate pre-reject hook below. */
static int ctx_txn_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct ctx_txn_state *st = (struct ctx_txn_state *)ri->data;
	const void __user *ubuf = (const void __user *)regs->regs[1];
	size_t size = (size_t)regs->regs[2];
	char kbuf[SUSFS_CTX_BUF];
	size_t n;

	if (ctx_hide_empty() || !ubuf || !size)
		return 1;
	if (!susfs_is_current_proc_umounted_app())
		return 1;

	n = min(size, sizeof(kbuf));
	if (copy_from_user_nofault(kbuf, ubuf, n))
		return 1;
	if (!ctx_buf_has_hidden_type(kbuf, n))
		return 1;

	st->file = (struct file *)regs->regs[0];
	return 0;
}

/* __nocfi because the drop below is an indirect call through a kallsyms-resolved pointer
 * (ctx_txn_set). A CFI-checked indirect call to an address the resolver found, not one the compiler
 * emitted a type id for, panics at run time, the same reason every resolver path in
 * symbol_resolver.c is __nocfi. */
static int __nocfi ctx_txn_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct ctx_txn_state *st = (struct ctx_txn_state *)ri->data;
	long rv = (long)regs_return_value(regs);

	/* A query that resolved staged its canonical answer. selinux_transaction_write() returns the
	 * write size (> 0) and leaves the answer in file->private_data for a read to pick up, so drop
	 * it (set size 0) before the errno below says the type is unknown, or that read would hand back
	 * the very answer the errno denies. rv > 0 also means simple_transaction_get() ran, so
	 * private_data is set and the drop cannot fault. A query that already failed (rv <= 0) staged
	 * nothing, so only its errno is normalised, making a present-but-denied type (-EACCES)
	 * indistinguishable from an absent one (-EINVAL). */
	if (rv > 0 && ctx_txn_set)
		ctx_txn_set(st->file, 0);
	atomic_inc(&n_txn_hits);
	regs_set_return_value(regs, (unsigned long)(long)-EINVAL);
	return 0;
}

static struct kretprobe krp_ctx_txn = {
	.kp.symbol_name = "selinux_transaction_write",
	.entry_handler = ctx_txn_entry,
	.handler = ctx_txn_ret,
	.data_size = sizeof(struct ctx_txn_state),
	.maxactive = 32,
};

static bool ctx_probes_armed;
static bool ctx_txn_is_kret;	/* which of krp_ctx_txn / kp_ctx_txn is live, for disarm and the /proc report */

/* Serialises arm/disarm. register_kprobe() answers -EINVAL once another task has resolved .addr,
 * and the failure branch below clears it, which without this lock would disarm a probe that is
 * live, the same hazard susfs_avc_spoof.c's avc_ctl_lock exists for. Two /proc writers can both
 * reach "list went from empty to one entry" at once, and init reaches this too. */
static DEFINE_MUTEX(ctx_ctl_lock);

/* Set by susfs_selinux_ctx_exit() while holding the lock, after which registration refuses. The
 * /proc node holds no module reference, so a write already inside ctx_proc_write() can reach this
 * during teardown. */
static bool ctx_exiting;

static int ctx_probes_register(void)
{
	int rc;

	mutex_lock(&ctx_ctl_lock);
	if (ctx_exiting) {
		mutex_unlock(&ctx_ctl_lock);
		return -ENODEV;
	}
	if (ctx_probes_armed) {
		mutex_unlock(&ctx_ctl_lock);
		return 0;
	}

	ctx_resolve_txn_set();

	/* attr/current stays a pre-reject whatever the query node does. Letting security_setprocattr()
	 * run would commit_creds() the new task SID, so a caller told the write failed would in fact
	 * have transitioned into the context it meant to hide. The error has to be faked before the
	 * body there, timing match or not. */
	rc = register_kprobe(&kp_ctx_attr);
	if (rc) {
		/* The address register_kprobe() resolved is already in the struct even on failure (see
		 * susfs_kprobe.h), so the next retry needs it cleared. */
		susfs_kp_forget_addr(&kp_ctx_attr);
		pr_warn("selinux_ctx: register_kprobe(security_setprocattr) failed %d, context hiding is off\n", rc);
		mutex_unlock(&ctx_ctl_lock);
		return rc;
	}

	/* The query node runs its body (pure) and the kretprobe rewrites the answer, which erases the
	 * pre-reject timing tell, but only when simple_transaction_set() resolved so the response the
	 * body stages can be dropped. Without it, fall back to the pre-reject kprobe, which stages
	 * nothing and stays leak-safe, trading the timing match for safety. */
	if (ctx_txn_set) {
		rc = register_kretprobe(&krp_ctx_txn);
		if (rc)
			susfs_krp_forget_addr(&krp_ctx_txn);
		else
			ctx_txn_is_kret = true;
	} else {
		rc = register_kprobe(&kp_ctx_txn);
		if (rc)
			susfs_kp_forget_addr(&kp_ctx_txn);
	}
	if (rc) {
		pr_warn("selinux_ctx: register %s(selinux_transaction_write) failed %d, context hiding is off\n",
			ctx_txn_set ? "kretprobe" : "kprobe", rc);
		unregister_kprobe(&kp_ctx_attr);
		susfs_kp_forget_addr(&kp_ctx_attr);
		mutex_unlock(&ctx_ctl_lock);
		return rc;
	}

	ctx_probes_armed = true;
	SUSFS_LOGI("selinux_ctx: hooks installed (selinux_transaction_write %s, security_setprocattr)\n",
		   ctx_txn_is_kret ? "kretprobe" : "kprobe");
	mutex_unlock(&ctx_ctl_lock);
	return 0;
}

static void ctx_probes_unregister_locked(void)
{
	if (!ctx_probes_armed)
		return;
	if (ctx_txn_is_kret) {
		unregister_kretprobe(&krp_ctx_txn);
		susfs_krp_forget_addr(&krp_ctx_txn);
		ctx_txn_is_kret = false;
	} else {
		unregister_kprobe(&kp_ctx_txn);
		susfs_kp_forget_addr(&kp_ctx_txn);
	}
	unregister_kprobe(&kp_ctx_attr);
	susfs_kp_forget_addr(&kp_ctx_attr);
	ctx_probes_armed = false;
	SUSFS_LOGI("selinux_ctx: hooks removed\n");
}

static void ctx_probes_unregister(void)
{
	mutex_lock(&ctx_ctl_lock);
	ctx_probes_unregister_locked();
	mutex_unlock(&ctx_ctl_lock);
}

/* True if @type (length @len, not NUL-terminated) is already in the list. Caller holds
 * ctx_hide_lock. */
static bool ctx_list_has(const char *type, size_t len)
{
	int i;

	for (i = 0; i < n_ctx_hide; i++) {
		if (strlen(ctx_hide[i]) == len && !memcmp(ctx_hide[i], type, len))
			return true;
	}
	return false;
}

static int ctx_list_add(const char *type, size_t len)
{
	unsigned long flags;
	int rc = 0, n;

	if (!len || len >= SUSFS_CTX_HIDE_LEN)
		return -EINVAL;

	spin_lock_irqsave(&ctx_hide_lock, flags);
	if (ctx_list_has(type, len)) {
		spin_unlock_irqrestore(&ctx_hide_lock, flags);
		return 0;
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

/* The list is copied out from under the lock before printing, because seq_printf() can grow the
 * seq buffer with kvmalloc(GFP_KERNEL), which must not happen while a spinlock is held. Off the
 * stack for the same reason sus_mount.c's keep-list snapshot is (SUSFS_CTX_HIDE_MAX *
 * SUSFS_CTX_HIDE_LEN is right at the -Wframe-larger-than boundary). */
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

	seq_printf(m, "armed=%d types=%d txn=%s\n", ctx_probes_armed ? 1 : 0, n,
		   ctx_txn_is_kret ? "kretprobe" : "kprobe");
	for (i = 0; i < n; i++)
		seq_printf(m, "%s\n", snap[i]);
	seq_printf(m, "hits: selinuxfs=%d setprocattr=%d\n",
		   atomic_read(&n_txn_hits), atomic_read(&n_attr_hits));
	kvfree(snap);
	return 0;
}

static int ctx_proc_open(struct inode *inode, struct file *file)
{
	/* 0777 node and this check, like every other control node here. A restrictive mode would
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
	/* Unlike avc_spoof's switch, this feature has no supercall side. The /proc node is the only
	 * way the list is ever changed, the same as susfs_hide_mounts.c's and susfs_hide_syms.c's list
	 * nodes. Without sus_path's LSM layer up (susfs_control_node_allowed() false) the list can
	 * never gain an entry, so the hooks correctly stay unarmed for this boot. */
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
	/* One critical section for "no more registrations" and the disarm, the same reason
	 * susfs_avc_spoof_exit() needs one. A /proc write holds no module reference and can be inside
	 * ctx_proc_write() right now. */
	mutex_lock(&ctx_ctl_lock);
	ctx_exiting = true;
	ctx_probes_unregister_locked();
	mutex_unlock(&ctx_ctl_lock);

	if (ctx_proc_entry) {
		proc_remove(ctx_proc_entry);
		ctx_proc_entry = NULL;
	}
}
