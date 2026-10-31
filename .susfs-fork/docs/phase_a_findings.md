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
4. p1-612: done except the 16K fixup fold. statx mnt_id masks and listmount/statmount hiding are
   implemented; mnt_id_unique crafting was tried and removed as unsafe for an LKM (see the p1-612
   outcome and listmount/statmount sections); the 16K fold stays build-gated.
5. p2-refactor: ed8a832 semantics onto our derived process state.
6. p4-selinux: selinux_hide as a new file with fork detection.
7. p5-webui: module WebUI toggles.
8. WildKernels: 16K fixup fold (folds into p1-612), dentry null guards (fold into Phase 3).
   Resolved below: neither applies. See "WildKernels and pershoot audit".

The memory-safety and statfs/cmdline fix batches need no code: they are already handled or are moot
because the LKM uses snapshots, real ids, atomic buffer swaps and kfree_rcu rather than the in-tree
edits those commits patched.

## p1-capacity outcome

The three accumulating rule tables now grow on demand instead of refusing rules at the old small
fixed caps (32/64/64), up to a hard ceiling of 1024 entries each. The ceiling is there because every
hooked read walks the table linearly (kstat with IRQs off), so an unbounded table would also mean an
unbounded per-call cost and pinned kernel memory from a runaway root-side script; a full table
answers -ENOSPC, and an allocation failure while growing answers -ENOMEM (no longer folded into
-ENOSPC):

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

## p1-race outcome

- 273ae36 (clone_mnt race): not applicable. Upstream's race is in its own clone_mnt patch, between
  the VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT flag and the susfs_is_sdcard_android_data_not_decrypted
  static key flipping mid-clone, which could free a mismatched id from mnt_id_ida. This LKM patches
  none of those: it marks mounts by taking a REAL id from mnt_id_ida/mnt_id_xa and, under
  namespace_sem, releases the orphaned original id and any unused batch id exactly once each while
  the kernel frees the new id on umount. No flippable key gates the free, so the window cannot open.

- 8879282 (mount minor-dev gap): a real detection vector (JingMatrix Demo) that upstream closes by
  allocating ksu-domain anon-bdev minors from a high range (DEFAULT_KSU_MNT_MINOR_DEV = 1 << 12) in
  get_anon_bdev(). Not implemented: we do not hook get_anon_bdev, the hook would fire for every anon
  mount on the system (tmpfs, overlayfs, ...) and would have to free the low minor and re-allocate a
  high one from the private unnamed_dev_ida under a probe, and an LKM loaded after boot cannot fix
  the minors of mounts KernelSU already created. Deferred to the build stage where the get_anon_bdev
  hook can be gated tightly on the ksu domain and stress-tested.

## p1-612 outcome

- mnt_id_unique crafting (removed): c71bdb0 gave each marked mount atomic64_read(mnt_id_ctr) + a
  private counter, the shape of upstream 7d91da2. Upstream does that in its allocators, before the
  mount is inserted; the module rewrote it on mounts already in ns->mounts, which on 6.12+ is an
  rb-tree keyed on mnt_id_unique (mnt_add_to_ns(), 6.12:1139, 6.18:1092). Rewriting the key in place
  breaks mnt_find_id_at() for statmount, listmount paging and the /proc/mounts seq position, and
  the crafted values also collided with the ids the kernel's counter handed to the next real
  mounts. The mount now keeps the id the kernel gave it at allocation, which is already in range
  with no gap, and the id is only recorded for the listmount/statmount filter.
- statx mask handling (verified, no change): the two mask bits land different values in the single
  stx_mnt_id field. STATX_MNT_ID returns the KSU-range mnt_id, which the statx return-probe maps to
  the original via sus_mount_shown_for(). STATX_MNT_ID_UNIQUE returns the kernel's own unique id,
  which sus_mount_shown_for((int)id) finds no map for and leaves intact; that id is still hidden
  from enumeration by the listmount/statmount probes.
- listmount/statmount hiding (now implemented, see its own section below). The earlier note that a
  return probe "lacks the per-mount struct context" was wrong: it does not need the struct, only the
  64-bit mnt_id_unique, which we already record when we mark a mount.
- the 16K fixup fold remains build-gated: it needs 16K-page handling that cannot be validated blind.

## 6.18 mnt_id_xa audit (previously build-gated, now source-confirmed)

The four points `parity.json`'s "audits" entry listed as build-gated were settled by fetching
`fs/namespace.c`, `lib/xarray.c`, `include/linux/xarray.h` and `include/linux/types.h` from the
real `android17-6.18` branch (kernel 6.18.33) with `tools/fetch_kernel_files.py`, cross-checked
against `android16-6.12` (6.12.96) for the same files:

- `xa_lock()` on `mnt_id_xa` is correct: the xarray carries no `XA_FLAGS_LOCK_IRQ`/`LOCK_BH`, so
  `xa_lock()` is unconditionally `spin_lock()`, matching the kernel's own `mnt_alloc_id()`/
  `mnt_free_id()` on the same object.
- A NULL entry in `__xa_alloc()` becomes `XA_ZERO_ENTRY` and the slot's free mark is cleared, so
  it is genuinely taken; `xa_erase()`/`__xa_erase()` genuinely frees it back. `mnt_id_xa` has no
  other reader in `fs/namespace.c`, so a reserved slot holding `XA_ZERO_ENTRY` instead of a real
  `struct mount *` is never dereferenced.
- `mnt_id_xa` is `static`, resolved via kallsyms like every other static data symbol this module
  reads.
- `ns->mounts` is an rb-tree ordered by `mnt_id_unique` on both trees (`mnt_add_to_ns()`), so the
  module must never write that field on a mount already inserted. This audit originally covered
  `mnt_id_ctr`'s type change (6.12 `atomic64_t`, 6.18 plain `u64`) for the crafting read; the
  crafting is removed, so `mnt_id_ctr` is no longer resolved or read at all.
- The allocation range `sus_mount_ida_alloc()` uses (`[DEFAULT_KSU_MNT_ID, INT_MAX-1]`) is a
  strict subset of the kernel's own `xa_limit_31b = [0, INT_MAX]`, so a marked mount's id is
  always one the kernel's own allocator could have produced.

The xarray points found no bug. The crafting did have one (in-place rewrite of an rb-tree key,
found in review afterwards) and was removed; see the p1-612 outcome.

## WildKernels and pershoot audit: nothing to port

Checked simonpunk/susfs4ksu (`abi_drift.py` against a freshly fetched clone: zero new commits
to `kernel_patches/` on any stable branch beyond what `triaged` already covers), then
WildKernels/GKI_KernelSU_SUSFS and gitlab.com/pershoot/susfs4ksu for anything that affects this
module and is not yet reflected here. Nothing does, for one structural reason that applies to
every candidate found: WildKernels and pershoot both build SUSFS the way upstream ships it, text
patched into the kernel tree and compiled in with the KSU driver. This module never patches
kernel source or KSU source. It loads standalone and reaches both through kallsyms, kprobes and
a syscall-table entry. Most of what those two repos fix is therefore patch-context drift between
an evolving kernel tree and a text patch, something an LKM cannot have because it has no text
patch to go stale.

Specific candidates checked, each a mechanical reason, not a guess:

- WildKernels' `fs/notify/fdinfo.c` "fake patch" fix (`mark->ignored_mask` -> 
  `inotify_mark_user_mask(mark)`, commit 9cead8e): fixes a text-patch hunk that no longer matches
  the kernel's own `inotify_fdinfo()` source after an AOSP refactor. `susfs_kstat.c`'s inotify
  hook never reads that field; `kstat_fdinfo_inotify()` parses the RENDERED fdinfo line as text
  (`kstat_fdinfo_hex()` et al.), so whichever internal helper the kernel used to print the number
  is invisible to us. Not applicable.
- WildKernels' `__fold_filemap_fixup_entry` stub (commit b435a9d) and pershoot's "Toolkit
  coexistence" / "no features" resyncs of `kernel_patches/fs/susfs.c` (commits 161c058,
  6387756): all three patch code that runs INSIDE the kernel's `show_map_vma()`/`fs/susfs.c`,
  i.e. code the built-in patch inserts into the function itself. Our `susfs_kstat.c` and
  `susfs_open_redirect.c` hook `show_map_vma` with a kretprobe that fires AFTER the real,
  unpatched function has already run (see the note above `struct kretprobe krp_kstat_map_vma`),
  so the kernel's own 16K fixup-fold call already ran, unconditionally, before we ever see the
  line - there is no early-return branch on our side for it to skip. `fs/susfs.c` does not exist
  in this module at all; 6387756's underlying upstream commit (44a893a6, NULL deref in
  get_enabled_features) was already independently confirmed handled in `susfs_supercall.c`.
  Not applicable, on both counts.
- pershoot's SELinux time side-channel fix (commit 35b2a01, 256 lines of
  `security/selinux/hooks.c` and `selinuxfs.c`): migrates KernelSU-Next's OWN `selinux_hide`
  implementation from a `fake_state` swap to the `backup_sepolicy`-based `_with_policy` calls, to
  close a timing gap between a hidden and a real context lookup. This is a fix to the exact
  mechanism `susfs_selinux_hide.c`'s header explains we do not reimplement: `backup_sepolicy` is
  created and freed by KernelSU's own policy-apply path, and a correct second copy would mean
  rebuilding this very mechanism, timing fix included. Since we only detect whether the running
  KernelSU has `selinux_hide` at all, a timing fix inside that feature's native implementation is
  not ours to carry. Not applicable.
- "Dentry null guards": no commit matching this was found in WildKernels' current history
  (checked commit messages and `.github/actions/susfs*` content for `dentry`/`d_inode`/
  `IS_ROOT`). Every direct `->d_inode` dereference in this module's kprobe context is already
  guarded (`sus_mount_ident_add()`: `if (!root || !root->d_inode) return;`); every `d_inode()`
  call elsewhere runs on a dentry a successful path lookup already produced. Closing this item:
  either it was resolved upstream before this audit, or it did not name a real gap.

Net result: both repos' current fixes target the built-in compile-time architecture this module
does not share. No patch, workaround or code change is needed from either source right now.

## listmount(2)/statmount(2) hiding (implemented, unvalidated)

The three remaining gaps were (a) listmount/statmount, (b) the fdinfo inotify SUS_MOUNT branch, (c)
the anon-bdev minor. Only (a) can be made regress-safe with the module's probe primitives; it is now
implemented in `sus_mount.c` under `#if >= 6.12` (the only KMIs with these 6.8+ syscalls).

How it works:

- A bounded sorted table (`sus_mount_uniq[]`, 1024 slots, `uniq_lock`) records the 64-bit
  `mnt_id_unique` of every mount we mark - recorded in the scan and in the `attach_recursive_mnt`
  return handler (mounts that appear later). Only the kernel's own ids are recorded, never crafted
  ones: the unique id is a monotonic counter the kernel never reuses (`fs/namespace.c`:
  `atomic64_inc_return(&mnt_id_ctr)` on 6.12, `++mnt_id_ctr` on 6.18), so a recorded id can never
  later name a different mount and the table needs no teardown on umount. It persists across disable/re-enable on purpose: the re-scan skips
  already-marked mounts, so clearing it would lose them.
- Inline filter, the same point as upstream's hunk (a `continue` right after the loop's
  `is_path_reachable()` check). The `do_listmount` entry probe records the task and `&kls->root` in
  a 16-slot table (`sus_mount_lm[]`, `lm_lock`) when the reader is hidden. While the task is listed,
  an `is_path_reachable()` return probe forces 0 for a mount of ours, so the loop skips it and the
  page fills with real mounts. The first call (orig against `&kls->root`, which decides `-EPERM` for
  the whole listing) is told apart by its root argument and left alone. The `do_listmount` return
  probe removes the slot.
- Fallback compaction: the same return probe drops any of our ids still in `kls->kmnt_ids` and
  lowers the count before the syscall copies the array out. With the inline filter working it finds
  nothing.
- The id test is by identity (`sus_mount_uniq_has`), a superset of upstream's KSU-range `mnt_id`
  test, so it also hides mounts the `attach_recursive_mnt` path marked.
- A kretprobe on `do_statmount` forces `-ENOENT` (its own answer for an unknown id) when the
  requested id is ours and the reader is hidden. Upstream does not hide statmount; this is a
  deliberate, documented widening, because hiding listmount alone leaves statmount as a one-call
  oracle for any id a detector already holds.

Why it is regress-safe:

- The `struct klistmount` mirror is byte-identical on android16-6.12 and android17-6.18 (verified
  against both sources); only `kmnt_ids`/`nr_mnt_ids` are read and only the count in x0 is written.
- Overriding the return value in a kretprobe handler is sound on arm64: `kretprobe_brk_handler()`
  runs the handler on the exception `pt_regs` (where x0 holds the function's just-returned value) and
  the exception return restores that same `pt_regs`, so writing `regs->regs[0]` changes the effective
  return (confirmed in `arch/arm64/kernel/probes/kprobes.c` on both trees).
- `is_path_reachable()` is shared: `path_is_under()` (exported, used by openat2
  `RESOLVE_BENEATH`/`RESOLVE_IN_ROOT`), `do_pivot_root()` and `do_statmount()` call it too. An
  unscoped override would make those scoped lookups fail with `-EXDEV` under our mounts. The probe
  only acts for a task listed in `sus_mount_lm[]`, which only `do_listmount` adds to, so those
  callers are never changed. The table is cleared when the probes are unregistered: a call in flight
  at that moment never runs its return handler, and its stale slot would otherwise filter that task's
  later `is_path_reachable()` calls after a re-enable.
- Compaction alone is not enough, which is why the inline filter exists. The caller pages from the
  last id it received (`mnt_find_id_at(ns, last_mnt_id + 1)`) and stops on a 0 return. A partly-ours
  page can safely come back short, but a FULL page that is entirely ours cannot be lowered to 0
  without ending the enumeration, so it goes out as built (`listmount full=`). With a buffer of 1,
  every one of our mounts is such a page. So when the inline filter is not live (probe did not arm,
  `lm_full`, missed instances, or LTO inlined do_listmount's own call), a small buffer sees every
  marked mount. `mount_stat` shows which mode is live: `listmount_inline ... (probe=1)` with
  `filtered=` rising and `listmount dropped=0` is the inline mode.
- Cost: a hidden reader's listmount pays one table scan per mount in the loop; every other
  `is_path_reachable()` caller pays a 16-entry pointer scan and returns.
- The gate (`sus_mount_hidden_reader`) is the umount predicate, so su, the manager and su-granted
  apps are never touched. It is safe from the preempt-disabled handler: across all five supported
  forks `ksu_uid_should_umount()` takes only `rcu_read_lock()` and a `kref_put`/`kfree_rcu`, never a
  mutex (read the fork sources to confirm, since the LKM substitute calls KernelSU here where
  built-in susfs would read a cheap `TIF_PROC_UMOUNTED` flag).
- Fail-open arming: `do_listmount`/`do_statmount` are static and `is_path_reachable()` has few
  callers, so LTO may inline any of them. A probe that does not register leaves its path unfiltered,
  logged, never a crash. The QEMU smoke asserts all three arm on 6.12 and 6.18 (`lm_probes=1,1,1`),
  and `tools/verify-gki.sh` checks the same on a device.

Unvalidated: nothing here has been built or booted. New counters are on `mount_stat`
(`uniq:`, `listmount:`, `listmount_inline:`, `statmount:`).

## fdinfo inotify SUS_MOUNT branch (b): blocked, not a regression

Upstream's `inotify_fdinfo()` SUS_MOUNT branch re-resolves a watched file's path with `d_path()` then
`kern_path()` to print the inode as seen WITHOUT the KSU mount. `kern_path()` sleeps, and our only
hook there is a kretprobe (preempt disabled), so this cannot be ported with the current primitives.
What is already covered: `sus_mount`'s fdinfo probe rewrites the `mnt_id`, and `susfs_kstat`'s
`kstat_fdinfo_inotify()` rewrites the printed ino/sdev from the kstat table. Only the SUS_MOUNT
kern_path re-resolution is missing, and an fdinfo without it is no worse than upstream built without
that branch. Recorded as the one standing gap in `parity.json` (the fdinfo `missing` site).

## anon-bdev minor, commit 8879282 (c): deliberate non-port

Its prerequisite static key `susfs_is_sdcard_android_data_not_decrypted` is driven upstream by a
kthread + fsnotify group + delayed_work watching `/data/media/0` ("code straightly borrowed from
KernelSU's pkg_observer.c"), which the event-driven-only rule forbids and the LKM does not have, so
the branch would never fire. Independently, `get_anon_bdev()` runs for every anonymous superblock
system-wide; upstream pays nothing when the key is off, but a kprobe would add cost to every call for
a first-boot-before-FBE-decryption window that is marginal. Recorded under "triaged" in parity.json.

## Closing outcomes (p0, p1-618, p3, p4, p5)

- p0: abi_drift.py was already the upstream comparison tool, so no new script. Running it showed the
  parity.json pins two commits behind on every stable branch. Both commits are not applicable
  (KernelSU patch only; priority-filter UAF fix for two objects that are one RCU object here). Pins moved,
  reasons under "triaged" in parity.json. It now reports only the fdinfo kern_path gap.
- p1-618: no 6.18 source locally; the DDK and GKI builds are the validation. The internal checks and the
  four points the build must settle are under "audits" in parity.json.
- p4: selinux_hide stays in KernelSU. Five of six forks ship it and hook selinuxfs and setprocattr at
  run time; a module copy would patch the same slots twice. Recorded as ksu-side.
- p5: module/toggle.sh plus webroot/index.html for the two on/off nodes (enable_log, avc_spoof). Saved in
  /data/adb/susfs_guard_lkm/toggles, re-applied by load.sh after a load. Host test: tools/test_toggle.py.
  Unverified until a device run: that the loader's context can write the nodes at boot (a failure is
  logged and never fails the boot).
- p3: reviewed what this branch changed, not every file. Found and fixed one bug in sus_map add (a freed
  slot hid a later duplicate; the old code had it too). The open_redirect add path and the kstat
  lookup-then-append callers hold no entry pointer across a grow. Not done: a line-by-line read of the
  other kernel files, and kstat_table_grow still copies inside the IRQ-off lock.
