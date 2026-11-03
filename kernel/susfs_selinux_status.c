// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_selinux_status.c keeps /sys/fs/selinux/status unchanged for KernelSU-origin
 * policy edits. This reproduces, from an LKM, the part of upstream's
 * susfs_is_current_ksu_domain() that gates the SELinux status page.
 *
 * libselinux mmaps /sys/fs/selinux/status so apps can detect policy reloads and
 * enforcing changes by watching a sequence counter. KernelSU's sepolicy pushes bump that
 * counter via reset_avc_cache(), which reveals a policy edit even when no app was
 * installed or updated.
 *
 * Upstream skips the bump for KernelSU-domain writes. The AVC is reset separately by
 * avc_ss_reset(), so skipping the status update changes only what userspace watchers see,
 * not what the kernel enforces. A kprobe pre_handler skips the whole selinux_status_update_*()
 * call for KernelSU-origin callers (via susfs_probe_return()), leaving sequence, policyload
 * and enforcing unchanged.
 *
 * The gate has two halves because uid 0 and other uids are identified differently.
 *
 * uid 0 is identified by its SELinux domain, using the same direct secid compare as
 * sus_mount.c and susfs_avc_spoof.c, against this file's own status_su_ctx (per-feature,
 * not shared, see susfs_open_redirect.c's or_su_ctx comment; defaults to "u:r:su:s0", see
 * the status_su_ctx declaration for why that differs from the other three files).
 * KernelSU's own uid-0 predicate (__ksu_is_allow_uid_for_current() -> is_ksu_domain(),
 * which checks the "u:r:su:s0" fallback documented in ksu_allow_gate.h) is deliberately
 * not used: on a gki-android16-6.12 Cuttlefish guest with KernelSU-Next it returned false
 * for a real su-escalated root shell in selinux_status_update_setenforce(). A uid=0 kind=1
 * hide=0 trace showed its SID/secid caching disagreed with the audit log's subj=u:r:su:s0
 * for that process, so root is not routed through it here.
 *
 * Other uids are answered by KernelSU's own allowlist (manager app, per-profile su-granted
 * apps). An app's domain is whatever it was installed with, so there is no fixed SELinux
 * domain to compare; susfs_ksu_allow_uid() is the only answer. It is UID based
 * (is_uid_manager() plus a hash lookup), not SID based, so the uid-0 finding above does not
 * apply. KernelSU must resolve first: the kind==0 strict fallback would otherwise answer
 * uid 0 itself, but this half never asks about uid 0, so that fallback never fires and
 * nothing is hidden until KernelSU resolves.
 *
 * Divergence from upstream: upstream keys both halves on one SELinux ksu-domain SID. This
 * keys the root half on a locally resolved SID (configurable, defaulting to a different
 * domain than upstream) and the app half on KernelSU's allowlist. Recorded in
 * .susfs-fork/parity.json.
 *
 * The feature is always armed; there is no runtime switch or admin list. Each probe arms
 * independently, and an unresolved symbol disables only its half (logged at init).
 * /proc/susfs_selinux_status is read-only and reports the armed state and per-writer skip
 * counters for testing and diagnosis.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/mutex.h>
#include <linux/atomic.h>
#include <linux/cred.h>		/* current_uid() through the gate */
#include <linux/security.h>	/* security_secctx_to_secid() for status_su_ctx */

#include "susfs_log.h"
#include "susfs.h"		/* susfs_expose_proc, susfs_control_node_allowed() */
#include "susfs_kprobe.h"	/* susfs_kp_forget_addr() */
#include "ksu_allow_gate.h"	/* susfs_ksu_allow_uid(), susfs_ksu_allow_kind, susfs_control_visible() */
#include "symbol_resolver.h"	/* find_kernel_symbol_exact() for security_cred_getsecid */

static atomic_t n_policyload_skips = ATOMIC_INIT(0);
static atomic_t n_setenforce_skips = ATOMIC_INIT(0);

/* su/ksu domain this file hides uid 0 for, resolved to a sid at init. Private name for the
 * same reason as sus_mount.c's su_ctx, susfs_avc_spoof.c's avc_su_ctx and
 * susfs_open_redirect.c's or_su_ctx: a shared default would let one feature's override
 * silently change another's gating.
 *
 * The default differs on purpose. Those three default to SukiSU's "u:r:ksu:s0", but this
 * feature is framed on KernelSU throughout (reset_avc_cache(), KERNEL_SU_CONTEXT).
 * KernelSU-Next's own kernel/selinux/selinux.c and the audit subj= field on the tested
 * Cuttlefish guest both point to "u:r:su:s0", so that is the default here. SukiSU users
 * override with susfs_guard_lkm.status_su_ctx=u:r:ksu:s0, the opposite direction from the
 * other three files. */
static char status_su_ctx[128] = "u:r:su:s0";
module_param_string(status_su_ctx, status_su_ctx, sizeof(status_su_ctx), 0644);
static u32 status_su_sid;

/* Resolved from kallsyms, as sus_mount.c resolves the same symbol: not every KMI exports it
 * to modules. NULL means uid 0 is never hidden (logged at init). */
static void (*pfn_status_cred_getsecid)(const struct cred *cred, u32 *secid);

/* __nocfi: calls a kallsyms-resolved kernel symbol through pfn_status_cred_getsecid, the same
 * reason sus_mount_is_su_domain() in sus_mount.c carries the attribute (see that comment for
 * the kCFI panic it avoids). Returns true only for a caller whose status-page update should be
 * hidden; see the file header for why uid 0 and other uids are tested differently. */
static __nocfi bool status_hide_current(void)
{
	uid_t uid = current_uid().val;

	if (uid == 0) {
		u32 sid;

		if (!pfn_status_cred_getsecid || !status_su_sid)
			return false;
		pfn_status_cred_getsecid(current_cred(), &sid);
		return sid == status_su_sid;
	}

	if (READ_ONCE(susfs_ksu_allow_kind) == 0)
		return false;
	return susfs_ksu_allow_uid(uid);
}

/* selinux_status_update_policyload() stores the new load count and bumps the page sequence.
 * For a KernelSU-origin caller the whole function is skipped, so an app watching the page sees
 * no reload. Arguments differ by version (<6.4 takes a leading struct selinux_state *), but
 * none are read here, since the decision is only skip-or-not, so one handler serves every KMI. */
static int status_policyload_pre(struct kprobe *kp, struct pt_regs *regs)
{
	if (!status_hide_current())
		return 0;
	atomic_inc(&n_policyload_skips);
	susfs_probe_return(regs);
	return 1;
}

/* selinux_status_update_setenforce() stores the new enforcing flag and bumps the sequence.
 * Skipped the same way for a KernelSU-origin caller, so a su-side setenforce leaves the page's
 * enforcing flag and sequence unchanged, matching upstream. A boot-time setenforce by init is
 * not KernelSU-origin and is left alone. */
static int status_setenforce_pre(struct kprobe *kp, struct pt_regs *regs)
{
	if (!status_hide_current())
		return 0;
	atomic_inc(&n_setenforce_skips);
	susfs_probe_return(regs);
	return 1;
}

static struct kprobe kp_policyload = {
	.symbol_name = "selinux_status_update_policyload",
	.pre_handler = status_policyload_pre,
};

static struct kprobe kp_setenforce = {
	.symbol_name = "selinux_status_update_setenforce",
	.pre_handler = status_setenforce_pre,
};

static bool policyload_armed;
static bool setenforce_armed;

/* Serialises arm and disarm. init arms, exit disarms. A register_kprobe() that fails after the
 * kernel resolved .addr must have it cleared (susfs_kprobe.h) before the struct can be reused,
 * the same hazard susfs_avc_spoof.c's avc_ctl_lock guards against. There is no re-enable path,
 * but exit can run while init is still in flight on another cpu, so the pair stays locked. */
static DEFINE_MUTEX(status_ctl_lock);
static bool status_exiting;

/* Arms one probe. A symbol that does not resolve (inlined, or absent on this KMI) leaves that
 * half off (logged); the function then behaves as the kernel does by default, the pre-module
 * behaviour, not a crash. */
static bool status_arm_one(struct kprobe *kp)
{
	int rc = register_kprobe(kp);

	if (rc) {
		susfs_kp_forget_addr(kp);
		pr_info("selinux_status: register_kprobe(%s) failed %d, that half stays off\n",
			kp->symbol_name, rc);
		return false;
	}
	return true;
}

static void status_disarm_one_locked(struct kprobe *kp, bool *armed)
{
	if (!*armed)
		return;
	unregister_kprobe(kp);
	susfs_kp_forget_addr(kp);
	*armed = false;
}

static int status_proc_show(struct seq_file *m, void *v)
{
	seq_printf(m, "armed: policyload=%d setenforce=%d root=%d ksu=%d\n",
		   policyload_armed ? 1 : 0, setenforce_armed ? 1 : 0,
		   (pfn_status_cred_getsecid && status_su_sid) ? 1 : 0,
		   READ_ONCE(susfs_ksu_allow_kind) ? 1 : 0);
	seq_printf(m, "skips: policyload=%d setenforce=%d\n",
		   atomic_read(&n_policyload_skips), atomic_read(&n_setenforce_skips));
	return 0;
}

static int status_proc_open(struct inode *inode, struct file *file)
{
	/* Plain 0444 perms would return EACCES to an app, proving the node exists before sus_path
	 * could answer ENOENT. Gate on visibility instead, as every other control node does. */
	if (!susfs_control_visible())
		return -ENOENT;
	return single_open(file, status_proc_show, NULL);
}

static const struct proc_ops status_proc_ops = {
	.proc_open = status_proc_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static struct proc_dir_entry *status_proc_entry;

int susfs_selinux_status_init(void)
{
	int err;

	pfn_status_cred_getsecid = (void *)find_kernel_symbol_exact("security_cred_getsecid");
	err = security_secctx_to_secid(status_su_ctx, strlen(status_su_ctx), &status_su_sid);
	if (err) {
		pr_warn("selinux_status: secctx_to_secid(%s) failed %d\n", status_su_ctx, err);
		status_su_sid = 0;
	}
	if (!pfn_status_cred_getsecid || !status_su_sid)
		pr_warn("selinux_status: su ctx \"%s\" -> sid %u, getsecid %px. uid 0 is never hidden until this resolves (override with susfs_guard_lkm.status_su_ctx)\n",
			status_su_ctx, status_su_sid, pfn_status_cred_getsecid);
	else
		SUSFS_LOGI("selinux_status: su ctx \"%s\" -> sid %u\n", status_su_ctx, status_su_sid);

	mutex_lock(&status_ctl_lock);
	if (!status_exiting) {
		policyload_armed = status_arm_one(&kp_policyload);
		setenforce_armed = status_arm_one(&kp_setenforce);
	}
	mutex_unlock(&status_ctl_lock);

	if (policyload_armed || setenforce_armed)
		SUSFS_LOGI("selinux_status: armed (policyload=%d setenforce=%d)\n",
			   policyload_armed ? 1 : 0, setenforce_armed ? 1 : 0);
	else
		pr_info("selinux_status: no status-page symbol resolved, the page is left to the kernel\n");

	/* The read-only report node is optional; the probes above are the feature itself. */
	if (susfs_control_node_allowed()) {
		status_proc_entry = proc_create("susfs_selinux_status", 0444, NULL,
						&status_proc_ops);
		if (!status_proc_entry)
			pr_warn("selinux_status: proc_create(susfs_selinux_status) failed\n");
	} else {
		SUSFS_LOGI("selinux_status: /proc node not created (expose_proc=%d lsm=%d)\n",
			   (int)susfs_expose_proc, (int)sus_path_lsm_active());
	}
	return 0;
}

void susfs_selinux_status_exit(void)
{
	mutex_lock(&status_ctl_lock);
	status_exiting = true;
	status_disarm_one_locked(&kp_policyload, &policyload_armed);
	status_disarm_one_locked(&kp_setenforce, &setenforce_armed);
	mutex_unlock(&status_ctl_lock);

	if (status_proc_entry) {
		proc_remove(status_proc_entry);
		status_proc_entry = NULL;
	}
}
