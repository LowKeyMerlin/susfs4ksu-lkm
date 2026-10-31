# Test plan - capacity rework, mnt_id_unique, conflict guard

Covers the changes committed this cycle. Do not run yet; this is the plan to run once the pipeline
is triggered. The rule: all 16 kernels (8 KMIs x ddk/gki) must pass. One build passing while another
fails counts as a failure.

## 0. Build matrix (gate for everything below)

- Build `kernel/` against each of the 16 DDK images. A warning-free compile is required; the RCU
  flex-array rewrites must also compile under `CONFIG_PROVE_RCU` and `CONFIG_LOCKDEP`.
- A separate KASAN image per KMI family is needed for the memory-safety cases in sections 3 and 6.
  The growable tables are the reason: a blind pointer-lifetime bug would otherwise only surface as a
  rare crash under load, not in a plain build.

## 1. Load and conflict guard

1. Clean load on a vanilla (non-susfs) fork: `insmod`, then confirm the `/proc` control nodes exist
   and dmesg has no warning. `rmmod`, then `insmod` again (rollback path is exercised by the second
   load).
2. Built-in-susfs refusal: on a kernel whose image exports `susfs_update_sus_kstat` /
   `susfs_add_sus_path` / `susfs_spoof_uname`, load must fail with `-EEXIST` and log the marker it
   found, and must leave no `/proc` node and no armed hook behind.

## 2. Command dispatch (wrong caller / bad input, every feature)

For each feature's supercall and `/proc` write:
- non-root caller is rejected;
- wrong `magic2` (not `SUSFS_MAGIC`) is rejected;
- an unterminated or over-length `char[256]` path is rejected (`-ENAMETOOLONG`), not read past;
- a path that does not resolve returns the kernel error, not a partial rule.

## 3. Capacity growth (the main new code)

### 3a. sus_kstat (growable array under the reader spinlock)

- Add more than 32 rules (the old cap) one at a time; after each doubling boundary (16, 32, 64, ...)
  confirm every earlier rule still spoofs and no rule was dropped.
- Interleave `del` and re-`add` so slots churn while the table grows.
- `clear`, then add again (buffer kept across clear, re-grows).
- Under KASAN: the reallocation path (`kstat_table_grow`) must show no use-after-free when a reader
  (a stat syscall on a marked inode from an app) runs concurrently with the writer.
- Ceiling: add past `SUS_KSTAT_MAX_CAP` (1024); the add is refused with `-ENOSPC` and the earlier
  rules keep working. A grow allocation failure (fault injection) is reported as `-ENOMEM`, distinct
  from the full-table `-ENOSPC`.
- `rmmod` after a large table: no leak (kmemleak), no WARN; buffer freed after the drain.

### 3b. sus_map (RCU flex-array, lock-free readers)

- Add more than 64 rules; confirm hiding still applies to each in `/proc/<pid>/maps`.
- Concurrency: a tight loop reading `/proc/<pid>/maps` of a marked process while another thread adds
  rules across a grow boundary. Under KASAN + PROVE_RCU, the old-table free must not race the
  lock-free reader. Expect zero splats.
- Ceiling: add past `SUS_MAP_MAX_CAP` (1024); the add is refused with `-ENOSPC`, earlier rules keep hiding.
- Delete back below a doubling boundary (table does not shrink) and confirm readers stay correct.
- No duplicate after a delete: add A, add B, `del A`, add B again. `/proc/susfs_map` must list B
  once, and after `del B` the mapping must be visible again (before the fix a second copy of B
  kept it hidden). Repeat with the rule that was added first and the one added last.
- `clear`, re-add, `rmmod`; table freed via kvfree_rcu after the drain, no splat.

### 3c. open_redirect (RCU flex-array + index free list, every-open() reader)

- Fill more than 64 SIMULTANEOUS live rules (no delete between), forcing a real grow; confirm each
  redirect fires and the reverse faces (d_path, statfs, fdinfo, maps) answer from the snapshot.
- Add/delete churn WITHOUT exceeding 64 live: confirm slots are reused and the table does NOT grow
  (free list path).
- `clear` with more than 64 live rules: exercises the allocated-bitmap path in `or_clear_all`; also
  force the bitmap_zalloc failure fallback (fault injection) and confirm each rule is still dropped.
- Every-open() correctness across a grow: a workload opening redirected and non-redirected paths in
  a loop while rules are added. Under KASAN + PROVE_RCU, no use-after-free on the old table, and no
  rule missed (the live-count gate is raised before a new rule's slot is filled).
- OOM on grow: inject an allocation failure in `or_grow_locked`; `add` must return `-ENOMEM` with the
  table unchanged (no half-added rule, live count not bumped).
- Ceiling: fill past `SUS_OR_MAX_CAP` (1024) live rules; the add is refused with `-ENOSPC` (distinct
  from the OOM `-ENOMEM`), earlier redirects keep firing.
- `rmmod` after churn: table and free list freed, no splat, no leak.

## 4. mnt_id_unique, listmount and statmount (6.12+)

- `statx(STATX_MNT_ID)` on a marked mount maps to the original id; `statx(STATX_MNT_ID_UNIQUE)`
  returns the kernel's own unique id (not crafted, so no rb-tree key is ever rewritten). The su-domain
  caller sees the real mnt_id (the gate short-circuits).
- Probes armed: on both 6.12 and 6.18 images `mount_stat` shows `(probe=1)` on the `listmount`,
  `listmount_inline` and `statmount` lines (the QEMU smoke asserts this as `lm_probes=1,1,1`). A 0
  means LTO inlined that function on this build; record which, it decides the next two bullets.
- With the inline filter armed (`listmount_inline ... probe=1`): `listmount(2)` from a hidden reader
  returns no marked mount's unique id at any buffer size, including 1. Page through to the end and
  confirm none appears and every real mount does. Expect `filtered` to rise and `listmount
  dropped` to stay 0; `dropped > 0` here means do_listmount's call to is_path_reachable() was
  inlined while the out-of-line copy still exists, so the probe armed but did not see the loop.
- Fallback only (`listmount_inline ... probe=0`): pages that were partly marked mounts come back
  short, and a full page that is entirely marked mounts is returned unfiltered (`listmount full`
  rises). That page is the known leak in this mode, and buffer size 1 reaches it on every marked
  mount. Confirm real mounts after it are still returned (no early end-of-list).
- Not scoped too wide: while a hidden reader lists, `openat2(RESOLVE_BENEATH)` and
  `RESOLVE_IN_ROOT` under a marked mount from another task (and from the same task between
  listmount calls) behave as before, and `pivot_root` is unaffected. `filtered` only rises during
  listmount calls.
- A su-granted app and root see every mount through listmount, and `filtered` does not rise.
- `statmount(2)` on a marked mount's unique id returns `-ENOENT` for a hidden reader, the same as an
  unknown id; a su-granted app gets the real details.
- Concurrency: 32 hidden readers listing at once with buffer size 1 overflow the 16 `lm` slots
  (`lm_full` rises) and the overflowed calls fall back to compaction; nothing crashes. Disable the
  mount layer mid-listing and enable it again: the slots are cleared, and openat2 under a marked
  mount from those tasks still works afterwards.
- `do_listmount`/`do_statmount`/`is_path_reachable` inlined (simulate by denying the symbol): that
  probe does not arm, the rest keep working, and nothing crashes.

## 5. Unload safety (all features)

- After exercising every feature, `rmmod` must unregister all probes, drain in-flight wrappers, free
  all rule storage, and restore any taken-over syscall-table entries. Verify with KASAN + a second
  `insmod`/`rmmod` cycle.

## 6. Adversarial / stress (senior-validation lens)

- Run 3a-3c concurrently on a multi-core guest for several minutes under KASAN + LOCKDEP + PROVE_RCU.
- Fuzz the `/proc` writers with truncated, oversized and binary input.
- Randomised add/del/clear across grow boundaries on all three tables at once.

## 7. Per-fork and guest

- Repeat sections 1-5 on each of the five KernelSU forks on an Android Cuttlefish guest
  (`.susfs-fork/android/guest-test.sh`), and the host loader guard via
  `.susfs-fork/module/guard_test.sh` under sh, dash and busybox.

## Deferred (tracked, not in this cycle)

The 16K fixup fold and the get_anon_bdev minor-gap hook (8879282) are build-gated items recorded in
phase_a_findings.md; they are out of scope for this test pass. listmount/statmount hiding is written
but has not been built or booted, so section 4 is its first run.
