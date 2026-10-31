# KernelSU bridge contract

How this module reads the state a built-in susfs would get from a susfs-enabled KernelSU, without
being called by KernelSU and without patching it. The bridge resolves symbols by name at load and
reads them; it never links against kernelsu.ko. A missing symbol takes the documented fail-safe
branch, never a NULL call.

## What the bridge resolves

- Allow predicate (is the current task a granted root caller): `ksu_allow_gate.c` resolves, in order,
  `__ksu_is_allow_uid_for_current` then `ksu_is_allow_uid_for_current`. Fail-safe: strict (treat as
  not-allowed) when neither resolves, so the control-node gate stays root-only.
- Umount predicate (would KernelSU umount modules for this uid): `ksu_umount_gate.c` resolves
  `ksu_uid_should_umount`. Fail-safe: the pre-issue-34 answer (`uid >= 10000`) when it does not
  resolve.
- Manager transport: the manager sends susfs commands over `reboot(magic1, magic2, cmd, arg)` with
  `magic2 == SUSFS_MAGIC` and uid 0. `susfs_supercall.c` hooks `__arm64_sys_reboot` directly and
  claims that command, so the manager reaches the module whether or not KernelSU forwards it.
- SID state: derived in `susfs_avc_spoof.c` rather than taken from KernelSU's `susfs_set_batch_sid`.

## Per-fork status

The forks in `ksud_forks.json`: KernelSU (tiann), KernelSU-Next, SukiSU-Ultra, BakaSU, backslashxx,
rsuntk. The bridge is spelling-tolerant for the allow predicate and fails safe for all three
predicates, so a fork that spells a symbol differently degrades rather than breaks. Exact per-fork
symbol confirmation is a build-time check: each fork is built in CI and the load log reports which
predicate resolved (`susfs_ksu_allow_kind`, `susfs_ksu_umount_gate_off`). Confirm there, and add any
new spelling to the gate's candidate list. This is deferred with the rest of the pipeline work.

## Conflict rule

The module assumes a vanilla (non-susfs) fork. If the installed fork is itself susfs-enabled, a
built-in susfs is in the kernel image or in kernelsu.ko; `susfs_main.c` detects either at load
(upstream's `susfs_*` entry points, looked up in vmlinux and module kallsyms alike) and refuses to
load, so the two never both own SUSFS_MAGIC or the /proc/susfs_* nodes. A susfs loaded after this
module is not seen.
