# SUSFS for KernelSU (LKM Edition)

[![pipeline](https://github.com/LowKeyMerlin/susfs4ksu-lkm/actions/workflows/susfs-pipeline.yml/badge.svg?branch=susfs)](https://github.com/LowKeyMerlin/susfs4ksu-lkm/actions/workflows/susfs-pipeline.yml)
[![license](https://img.shields.io/badge/license-GPL--2.0-blue)](../LICENSE)

[SUSFS](https://gitlab.com/simonpunk/susfs4ksu) as a loadable kernel module. It loads into the
kernel you already run, next to KernelSU. No kernel build, no SUSFS patches.

[Install](#install) | [Loading](#loading) | [Boot guard](#boot-guard) | [Built-in or LKM](#built-in-susfs-or-lkm) | [Compatibility](#compatibility) | [Development](#development) | [Credits](#credits)

> [!CAUTION]
> The module runs inside the kernel. A bad build or a wrong `.ko` can leave a device in a bootloop.
> Keep your stock boot image (`init_boot.img`, or `boot.img` on older devices) and read
> [Boot guard](#boot-guard) before you flash.

## Highlights

* **Same functionality, no kernel build.** Hides paths, mounts, file stat, memory maps and more from
  apps, as SUSFS does when it is built into the kernel.
* **Boot guard.** Disables the module when boots do not finish, so a bad load does not repeat.
* **Early or late loading.** Loads at `post-fs-data`, earlier at `post-fs-data.d`, or by hand on a
  running system. Open file descriptors and running apps are covered from the first rule.
* **No idle cost.** With no rules the module does nothing. It has no timers, threads or polling.
* **Tested before it merges.** Every change is built, booted in QEMU, run against the KernelSU forks
  and run on an Android guest.

This is a fork of [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm). It adds a boot
guard, fixes found by booting real kernels, the latest upstream changes ported in, and a CI pipeline
that every change has to pass.

## Install

Needs an arm64 device with KernelSU or one of its forks, already up and running.

1. Download `ksu_susfs_lkm-module-<tag>-arm64.zip` from
   [Releases](https://github.com/LowKeyMerlin/susfs4ksu-lkm/releases), or from the artifacts of the
   latest successful `susfs-pipeline` run.
2. Flash it in the KernelSU manager and reboot. The installer picks the `.ko` for your kernel and
   writes `/data/adb/susfs_guard_lkm-install.log`. It refuses a manager that is not KernelSU.
3. Add rules through the `/proc/susfs_*` nodes, see [PROC_INTERFACES.en.md](../PROC_INTERFACES.en.md).

To remove it, disable the module in the manager, or run `rmmod susfs_guard_lkm` to unload it now.

## Loading

| Stage | How |
| --- | --- |
| `post-fs-data` | Default. |
| `post-fs-data.d` | `touch /data/adb/modules/susfs_guard_lkm/early_load` and reboot. |
| Manual | `ksud insmod <ko>`, or `susfs_insmod <ko>` without KernelSU. |

> [!TIP]
> Use `post-fs-data.d` when rules or kstat snapshots must exist before other modules mount.
> Delete `early_load` and reboot to go back to the default.

<details>
<summary>Loading by hand</summary>

```sh
ksud insmod /data/adb/loader/susfs_guard_lkm.ko    # KernelSU
susfs_insmod /data/adb/loader/susfs_guard_lkm.ko   # no KernelSU
rmmod susfs_guard_lkm                              # unload
```

Use the `.ko` that matches the kernel, for example `susfs_guard_lkm-android13-5.15.ko`.

</details>

## Boot guard

The guard sets a marker before the module loads and clears it once the boot has been up for ten
minutes. If the marker is still there at the next boot, that boot ended early. It counts against
the module unless someone asked for the end. A reboot or power-off from the menu, the manager or
adb is never counted, however often you do it. A power cut, a panic or a forced power-off is.
Two in a row disable the module instead of loading it again.

The guard tells the two apart by two signals that do not depend on each other: the shutdown it saw
begin, and the boot reason Android reports. Both have to be missing for a boot to count.

It also watches for a crash loop that never reboots. If zygote or SystemUI restart four times
while the boot is being watched, it disables the module and reboots.

The installer asks, with the volume keys, whether a trip disables all KernelSU modules (default)
or only this one. Magisk and APatch are not tested.

<details>
<summary>The device still does not boot</summary>

* Boot into KernelSU's safe mode, which loads no module. Its documentation gives the key sequence.
* Create `/data/adb/susfs_skip` from adb or recovery to keep this module from loading. Delete it to
  load again.
* Or delete `/data/adb/modules/susfs_guard_lkm`. The module is gone on the next boot.

</details>

## Built-in SUSFS or LKM

|  | Built-in SUSFS kernel | SUSFS as an LKM (this module) |
| --- | --- | --- |
| Setup | Patch KernelSU and the kernel, build, flash a boot image or an AnyKernel3 zip. Often a GKI kernel built from Google's artifacts. | KernelSU in LKM mode patches the boot partition your device uses, `init_boot` on newer devices and `boot` on older ones. This module is then installed like any KernelSU module. |
| Kernel | Replaced by your build. | Left as it is. |
| Hooks | Patched into the kernel source. No dependency on kprobes. | kprobes, syscall table wrappers and kallsyms lookups. Where they differ from upstream is listed in `.susfs-fork/parity.json`. |
| Active from | The start of boot. | When the module loads, `post-fs-data` by default or the earlier `post-fs-data.d`. |
| Updating SUSFS | New kernel build and flash. | Replace the module. |
| After an OTA | The kernel is replaced and has to be flashed again. | The module is in `/data/adb/modules` and is not part of the boot image. |
| Removing | Flash another kernel. | `rmmod`, or disable the module in the manager. |
| Needs | A kernel you can build and flash. Patches can differ per kernel version. | A module build for the kernel version (KMI), and kprobes, kallsyms and module loading enabled. |
| Devices | Works where a replacement kernel can be flashed, including Samsung with KNOX, where KernelSU's LKM mode does not work. | Needs KernelSU to run on the stock kernel. |
| Best when | You build your own kernel and want every upstream hook. | You keep the stock kernel, or want to update without flashing a kernel. |

> [!NOTE]
> KernelSU's own LKM and GKI modes are a different axis. They describe how KernelSU gets into the
> kernel. The table is about how SUSFS gets in. The module needs KernelSU running on the kernel and
> asks it which callers are apps, at every call.

## Compatibility

A kernel works if a module build matches its version and KernelSU supports the kernel. The device
does not have to be GKI supported, and the kernel does not need SUSFS patches.

* What KernelSU supports: its [README](https://github.com/tiann/KernelSU#compatibility-state) and
  [installation guide](https://kernelsu.org/guide/installation.html).
* The module is tested with: [`ksud_forks.json`](../.susfs-fork/ksud_forks.json).
* Test results per build: [Actions](https://github.com/LowKeyMerlin/susfs4ksu-lkm/actions).

## Development

`main` mirrors the parent repository and is never edited. `susfs` only adds files, so syncing the
parent cannot conflict.

* Added code and tests are in `.susfs-fork/`.
* Changes to files the parent owns are numbered patches in `.susfs-fork/patches/`.
* Workflows are named `susfs-*`. `susfs-sync` mirrors the parent every night and rebases `susfs`.
* New work is tried on a `test/<item>` branch, then squashed onto `susfs`. A push there runs the
  build and the QEMU smoke. `gh workflow run susfs-pipeline.yml --ref test/<item> -f full=true`
  adds the KernelSU forks and the Android guest. Which stages a branch runs is set in its
  `.susfs-fork/flow.json`.

## Credits

simonpunk for [SUSFS](https://gitlab.com/simonpunk/susfs4ksu), inforcqb for [susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm),
[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) for `patch_memory`, `lsm_hook` and
`symbol_resolver`, and the KernelSU projects this is tested against.

## License

[GPL-2.0](../LICENSE). For research and study, at your own risk.
