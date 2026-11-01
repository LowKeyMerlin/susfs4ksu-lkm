// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_selinux_hide.c is a read-only node. It reports whether the running KernelSU fork carries
 * its own selinux_hide (tiann/KernelSU, SukiSU-Ultra, BakaSU, KernelSU-Next, backslashxx).
 *
 * We do not reimplement it. selinux_hide answers from backup_sepolicy, a KernelSU internal whose
 * lifetime KernelSU owns (freed in ksu_selinux_hide_drop_backup_if_unused() once its own copy is
 * off). A second backup here would mean duplicating that whole mechanism.
 *
 * We only detect. Resolve ksu_selinux_hide_running via kallsyms on each read. Its presence means
 * the feature is compiled in, which is all ksud or the WebUI needs before offering a switch of
 * its own. Nothing to arm, nothing to write.
 */
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/cred.h>	/* current_uid(): the control-node gate */
#include "symbol_resolver.h"
#include "susfs_log.h"	/* SUSFS_LOGI */
#include "susfs.h"	/* susfs_expose_proc, susfs_control_node_allowed() */
#include "ksu_allow_gate.h"	/* susfs_control_visible(): the control-node gate */

/* ksu_kallsyms_lookup_name() (not the exact resolver) so a kernelsu.ko symbol is seen. Resolved
 * per read so a late-loaded KernelSU is still detected and an unloaded one is not read through a
 * stale pointer. The residual window is an unload between this lookup and the read below. */
static bool *selinux_hide_running(void)
{
	return (bool *)ksu_kallsyms_lookup_name("ksu_selinux_hide_running");
}

static int selinux_hide_proc_show(struct seq_file *m, void *v)
{
	bool *running = selinux_hide_running();

	seq_printf(m, "native_supported=%d native_running=%d\n",
		   (int)(running != NULL), running ? (int)READ_ONCE(*running) : 0);
	return 0;
}

static int selinux_hide_proc_open(struct inode *inode, struct file *file)
{
	/* 0777 by design. ENOENT comes from sus_path's hidden set, not the mode, so gate non-root
	 * here too. See susfs_enable_log.c log_proc_open(). */
	if (!susfs_control_visible())
		return -ENOENT;
	return single_open(file, selinux_hide_proc_show, NULL);
}

static const struct proc_ops selinux_hide_proc_ops = {
	.proc_open = selinux_hide_proc_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
	/* No .proc_write. Read-only node, so write(2) gets proc_reg_write()'s default -EINVAL. */
};

static struct proc_dir_entry *selinux_hide_proc_entry;

int susfs_selinux_hide_init(void)
{
	SUSFS_LOGI("selinux_hide: host feature %s at load\n",
		       selinux_hide_running() ?
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
