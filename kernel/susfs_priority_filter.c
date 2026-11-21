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
 *  - Hidden uids come from package names, which susfs_uid_filter.c resolves through
 *    /data/system/packages.list when the command arrives and again when the package list changes.
 *    A name that is not installed fails the command, so a typo is reported. Upstream skips it.
 *
 * Nothing runs unless a filtered syscall is made or the package list changes: no polling, timer
 * or thread. A lookup is one bit test.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/user_namespace.h>
#include <linux/compat.h>
#include <linux/resource.h>
#include <linux/ioprio.h>
#include <asm/ptrace.h>
#include <asm/unistd.h>

#include "susfs.h"
#include "susfs_abi.h"
#include "susfs_fp_hook.h"
#include "susfs_uid_filter.h"
#include "susfs_log.h"
#include "ksu_allow_gate.h"

/* AArch32 table numbers (arch/arm/tools/syscall.tbl). The native ones come from __NR_*, the two
 * tables are numbered differently, see struct susfs_fp_hook. */
#define COMPAT_GETPRIORITY_NR	96
#define COMPAT_SETPRIORITY_NR	97
#define COMPAT_IOPRIO_SET_NR	314
#define COMPAT_IOPRIO_GET_NR	315

/* The uids to hide, by package. The engine keeps the set current, see susfs_uid_filter.c. */
static struct susfs_uid_filter prio_filter = { .name = "priority_filter" };

static susfs_syscall_fn_t prio_orig_getpriority;
static susfs_syscall_fn_t prio_orig_setpriority;
static susfs_syscall_fn_t prio_orig_ioprio_get;
static susfs_syscall_fn_t prio_orig_ioprio_set;
static susfs_syscall_fn_t prio_orig_compat_getpriority;
static susfs_syscall_fn_t prio_orig_compat_setpriority;
static susfs_syscall_fn_t prio_orig_compat_ioprio_get;
static susfs_syscall_fn_t prio_orig_compat_ioprio_set;

/* ---- the check a syscall makes ---- */

/* Must the current caller not see this uid? The order keeps the common case cheap: non-apps and
 * callers asking about themselves never reach the bitmap, and KernelSU is asked only for a hidden
 * uid. */
static bool prio_hides(unsigned int who)
{
	const struct cred *cred = current_cred();
	kuid_t target;
	uid_t app;

	if (!who || __kuid_val(cred->uid) < SUSFS_UID_FILTER_MIN_UID)
		return false;
	target = make_kuid(cred->user_ns, who);
	if (!uid_valid(target) || uid_eq(target, cred->uid))
		return false;
	app = __kuid_val(target) % SUSFS_UID_PER_USER_RANGE;

	return susfs_uid_filter_has(&prio_filter, app) && !susfs_ksu_allow_current();
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

	susfs_uid_filter_supercall(&prio_filter, user->app_strings, &user->err);
}

/* ---- load and unload ---- */

/* All four or none. A filter covering three calls is worse than none: the fourth is a way around
 * it while the feature is advertised as working. */
int susfs_priority_filter_init(void)
{
	int i, rc;

	/* Without the package event the list goes stale when an app is reinstalled, which hides the
	 * wrong uid and shows the right one. */
	rc = susfs_uid_filter_attach(&prio_filter);
	if (rc)
		return rc;

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
	susfs_uid_filter_detach(&prio_filter);
	return rc;
}

void susfs_priority_filter_exit(void)
{
	bool armed = false;
	int i;

	for (i = 0; i < (int)ARRAY_SIZE(prio_hooks); i++) {
		if (!prio_hooks[i].installed)
			continue;
		susfs_fp_remove(&prio_hooks[i]);
		armed = true;
	}
	if (armed)
		susfs_fp_drain();

	/* No syscall is in a wrapper now, so nothing reads the set. */
	susfs_uid_filter_detach(&prio_filter);
}