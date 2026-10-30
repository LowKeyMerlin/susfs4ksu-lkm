# Phase A findings: audit before code

Method: read upstream from the local bare clone of susfs4ksu (stable gki-android* branches,
all at v2.3.0) and diff each listed fix commit and hook site against this module's `kernel/`
tree on susfs-dev. Read-only analysis. This file records what is already handled, what is
moot by design, and the narrow set of work that remains. It complements `parity.json`, whose
"reviewed" note says commit contents were not checked yet; this is that check.

## Command and hook-site parity

- Commands: `susfs_abi.h` defines all 24 `CMD_SUSFS_*` at the upstream values, identical across
  5.10, 6.1 and 6.12. `susfs_supercall.c` dispatches all 16 active commands; the 8 deprecated
  commands are intentionally unhandled. No command gap.
- Hook sites: every `susfs_*` call the 6.12 patch inserts maps to a mechanism in our tree
  (LSM slots for sus_path, `iterate_dir` for readdir, kretprobes for sus_kstat, kprobes for
  sus_mount and sus_map, syscall-table takeover for the priority filter and uname,
  `slow_avc_audit` for the AVC spoof, `saved_boot_config` rewrite for cmdline, hide_syms for
  kallsyms, `__arm64_sys_reboot` for dispatch). See `parity.json` for the per-site map.
- `drivers/input/input.c` and `fs/read_write.c` carry KernelSU hooks, not susfs. Out of scope.

## Upstream fix commits since v2.3.0: applicability

Already handled or moot by design (no code needed):

- `ad8e498` free new_entry on no-match update: moot. `susfs_update_sus_kstat` looks up first and
  returns `-ENOENT` before any allocation.
- `b56b5ac` KSTAT_SPOOF_CTIME_TV_SEC bit: already `1 << 8` in `susfs_abi.h`.
- `44a893a` NULL deref in get_enabled_features ENOMEM path: already handled more robustly in
  `susfs_supercall.c` with a dedicated BSS-zeroed static struct and a documented rationale.
- `8d7256b` and `b56617c` dangling `nd->name` in path_openat retry: moot. Open-redirect does not
  reuse `nd`; `susfs_opath.c` replaces the openat/openat2 syscall entries and `susfs_or_entry.c`
  runs its own `getname_flags` + `filename_lookup` + `putname`, with the 5.14-vs-5.15 ownership
  change handled explicitly. There is no `do_filp_open` retry path reading a freed filename.
- `8b25990` priority-filter UAF from missing `synchronize_rcu`: moot. `susfs_priority_filter.c`
  uses `kfree_rcu(old, rcu)` with a real `rcu_head` under `prio_lock`, which defers the free past
  a grace period and avoids the synchronous stall the upstream fix adds.
- `60024a4`, `6c2b504`, `357d43f`, `3d7dc14` statfs f_flags zeroed / wrong logic / wrapper rename:
  moot. `susfs_kstat.c` snapshots the real `struct kstatfs` (f_flags included) with the kernel's
  `vfs_statfs()` at rule-add time and answers statfs and fstatfs from that snapshot, so it never
  recomputes f_flags at read time where those bugs lived.
- `6d574eb` emit spoofed cmdline once outside the seqlock retry: moot. `spoof_cmdline.c` swaps the
  `saved_boot_config` pointer atomically and lets the kernel's own `seq_puts` emit it once; there
  is no seqlock retry loop in our path.
- `986cbfe` skip mount_lock in the fast path: our sus_mount path marks real ids rather than walking
  per read; confirm during Phase 3 that no hot read path takes mount_lock. Low priority.

Needs verification or a port (narrow):

- `a94015b` leak in vfs_statx_path with STATX_MNT_ID masks (6.12+): our stat path is kretprobe
  post-handlers, not the upstream vfs_statx_path edit. Verify our statx mnt_id handling on 6.12/6.18
  masks STATX_MNT_ID and STATX_MNT_ID_UNIQUE and leaks nothing.
- `7d91da2` craft mnt_id_unique for new ksu mounts (6.12+): likely a real gap. We assign a real
  `mnt_id` from `mnt_id_ida`, but the 6.12+ unique counter exposed through STATX_MNT_ID_UNIQUE and
  listmount/statmount is not crafted yet. Port under p1-612.
- `8879282` mount minor-dev gap: verify whether our approach allocates anon bdevs at all. If it
  reuses real superblock dev numbers it is moot; if a minor gap is observable, craft the minor.
- `273ae36` clone_mnt race when the static key flips during unshare: our marking mechanism differs
  from the upstream static-key swap. Examine the 50-patch hunk against `sus_mount.c` clone_mnt
  handling and confirm no equivalent race.

## KSU bridge

- Built-in contract confirmed from `10_enable_susfs_for_ksu.patch`: a susfs-enabled KSU calls
  `susfs_*`, reads `TIF_PROC_UMOUNTED`, and uses the SID helpers; the manager drives susfs over the
  reboot syscall with `magic2 == SUSFS_MAGIC`, uid 0.
- Our inversion: `ksu_allow_gate.c` and `ksu_umount_gate.c` resolve KSU's own predicates by name and
  read them; `susfs_supercall.c` hooks `__arm64_sys_reboot` and claims SUSFS_MAGIC directly; SID
  state is derived in `susfs_avc_spoof.c`.
- Open: (1) no guard against an already-susfs-enabled fork, which would double-create /proc nodes and
  double-dispatch SUSFS_MAGIC - add a load-time detect-and-back-off; (2) the allow/umount predicate
  spellings and the supercall transport must be mapped per fork into `abi_known.json`.

## Genuinely remaining work

1. ksu-conflict: detect built-in susfs at load, refuse to arm, fail-closed.
2. ksu-forks: per-fork symbol and transport map in `abi_known.json`.
3. p1-capacity: dynamic rule storage replacing the fixed arrays, with the LKM reader/unload rules.
4. p1-612: mnt_id_unique crafting, statx mnt_id masks, listmount/statmount hiding, 16K fixup fold.
5. p2-refactor: ed8a832 semantics onto our derived process state.
6. p4-selinux: selinux_hide as a new file with fork detection.
7. p5-webui: module WebUI toggles.
8. WildKernels: 16K fixup fold (folds into p1-612), dentry null guards (fold into Phase 3).

The memory-safety and statfs/cmdline fix batches need no code: they are already handled or are moot
because the LKM uses snapshots, real ids, atomic buffer swaps and kfree_rcu rather than the in-tree
edits those commits patched.

## p1-capacity outcome

The three accumulating rule tables now grow instead of refusing rules at a fixed cap:

- sus_kstat: growable array, reallocated under the writer mutex and swapped under the reader
  spinlock (readers already copy out under that spinlock). Freed on unload after the drain.
- sus_map: RCU-published flex-array table, used count stored inside it so a reader on an older
  table cannot overrun it; grown with a spare allocated outside the spinlock, old table freed with
  kvfree_rcu. Lock-free readers unchanged in shape.
- open_redirect: RCU-published flex-array table with an index-based free list grown alongside it;
  growth runs under or_lock before any accounting changes, old table freed with kvfree_rcu. The
  BITS_PER_LONG "marked" word in clear-all became an allocated bitmap. Reader gate moved to the
  live count the file already documented.

hide_modules is left bounded at 16 on purpose: it is a list of module NAMES to hide (default holds
only this module), not an accumulating rule set, and 16 covers every realistic hiding scenario. A
dynamic rewrite of its fixed 2D name arrays would add risk for no practical gain.

Unload frees follow the existing priority-filter reasoning: a kernel-owned kvfree_rcu needs no
rcu_barrier because the callback runs kernel code, not module code.
