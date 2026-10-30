/* SPDX-License-Identifier: GPL-2.0-only */
/* Just enough of <linux/types.h> for the uapi headers of the KernelSU forks. */
#ifndef SHIM_LINUX_TYPES_H
#define SHIM_LINUX_TYPES_H

#include <stdbool.h>

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef signed int __s32;
typedef __u64 __aligned_u64 __attribute__((aligned(8)));

#endif