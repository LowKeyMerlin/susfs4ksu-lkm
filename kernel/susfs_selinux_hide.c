// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_selinux_hide.c - reports whether the running kernel's own KernelSU fork carries
 * selinux_hide (kernel/feature/selinux_hide.c in tiann/KernelSU, SukiSU-Ultra, BakaSU,
 * KernelSU-Next and backslashxx; answers selinuxfs and setprocattr queries from a backup of
 * the pre-su policy), independent of this module.
 *
 * This module does not take the feature over.  What selinux_hide answers from -
 * backup_sepolicy - is a KernelSU-internal object (a full ksu_dup_sepolicy() plus an isid
 * load, see KernelSU's kernel/selinux/rules.c:apply_kernelsu_rules()) whose lifetime
 * KernelSU itself owns: it frees that backup in ksu_selinux_hide_drop_backup_if_unused() the
 * moment ITS OWN copy of the feature is off.  A second, independent backup here would have to
 * duplicate that whole mechanism and track every policy reload KernelSU does - not something
 * to hand-write without the fork's own kernel source and a device to boot it on.
 *
 * What this file does: resolve ksu_selinux_hide_running via kallsyms at load.  Its presence
 * means the running KernelSU build carries the feature AT ALL (compiled in), independent of
 * whether the user has it switched on - that is the one fact a caller (ksud, the WebUI) needs
 * to decide whether offering its own switch for the same thing would mean anything.  Read-only
 * node: there is no hook here to arm, so there is nothing to write.
 */
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/cred.h>	/* current_uid(): the control-node gate */
#include "symbol_resolver.h"
#include "susfs.h"	/* susfs_expose_proc, susfs_control_node_allowed() */
#include "ksu_allow_gate.h"	/* susfs_control_visible(): the control-node gate */

static bool *ksu_selinux_hide_running_ptr;

static int selinux_hide_proc_show(struct seq_file *m, void *v)
{
	seq_printf(m, "native_supported=%d native_running=%d\n",
		   (int)(ksu_selinux_hide_running_ptr != NULL),
		   ksu_selinux_hide_running_ptr ?
			   (int)READ_ONCE(*ksu_selinux_hide_running_ptr) : 0);
	return 0;
}

static int selinux_hide_proc_open(struct inode *inode, struct file *file)
{
	/* 0777 is deliberate (the ENOENT contract comes from sus_path's hidden set, not from the
	 * mode), so refuse non-root callers here too - see the note in susfs_enable_log.c's
	 * log_proc_open(). */
	if (!susfs_control_visible())
		return -ENOENT;
	return single_open(file, selinux_hide_proc_show, NULL);
}

static const struct proc_ops selinux_hide_proc_ops = {
	.proc_open = selinux_hide_proc_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
	/* No .proc_write: nothing here is this module's to arm (see the file banner). A write(2)
	 * answers -EINVAL by proc_reg_write()'s own default, which is the honest answer. */
};

static struct proc_dir_entry *selinux_hide_proc_entry;

int susfs_selinux_hide_init(void)
{
	ksu_selinux_hide_running_ptr =
		(bool *)find_kernel_symbol_exact("ksu_selinux_hide_running");
	SUSFS_LOGI("selinux_hide: host feature %s\n",
		   ksu_selinux_hide_running_ptr ?
			   "detected (ksu_selinux_hide_running resolved)" : "not detected");

	if (susfs_control_node_allowed()) {
		selinux_hide_proc_entry = proc_create("susfs_selinux_hide", 0777, NULL,
						      &selinux_hide_proc_ops);
		if (!selinux_hide_proc_entry)
			pr_warn("proc_create(susfs_selinux_hide) failed\n");
		else
			SUSFS_LOGI("susfs_selinux_hide: proc ready (/proc/susfs_selinux_hide)\n");
	} else {
		SUSFS_LOGI("susfs_selinux_hide: /proc node not created (expose_proc=%d lsm=%d)\n",
			(int)susfs_expose_proc, (int)sus_path_lsm_active());
	}
	return 0;
}

void susfs_selinux_hide_exit(void)
{
	if (selinux_hide_proc_entry) {
		proc_remove(selinux_hide_proc_entry);
		selinux_hide_proc_entry = NULL;
	}
}
