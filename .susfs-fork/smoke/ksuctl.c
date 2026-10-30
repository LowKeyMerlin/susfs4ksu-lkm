// SPDX-License-Identifier: GPL-2.0-only
/*
 * ksuctl - the part of ksud that the smoke test needs, for every KernelSU fork.
 *
 * ksud tells the kernel part about the boot stages and a manager app edits the app
 * profiles. A VM without Android has neither, so this client does it. It is built
 * against the uapi headers of the fork under test (-I<fork checkout>), so a change of a
 * request layout in a fork breaks the build instead of being sent in the old layout.
 *
 *   ksuctl event post-fs-data|boot-completed   report a boot stage (root)
 *   ksuctl umount UID                          ask whether UID gets the modules unmounted
 *   ksuctl granted UID                         ask whether UID has root granted
 *   ksuctl manager-toolkit UID                 name UID the manager, backslashxx only (root)
 *   ksuctl profile UID allow|deny|keep         set the profile of UID (manager only)
 *     allow  root granted
 *     deny   no root, modules unmounted
 *     keep   no root, modules left mounted
 *
 * Each command prints one line "ksuctl: <command> rc=<n> value=<n>" and exits with the
 * negated errno of the request, 0 on success, 2 on a usage error.
 *
 * Build: clang --target=aarch64-linux-gnu -O2 -nostdlib -static -fno-stack-protector \
 *        -fno-builtin -fuse-ld=lld -Wl,-e,_start -I<shim> -I<fork> -o ksuctl ksuctl.c
 */
#include "uapi/supercall.h"

#define SYS_ioctl	29
#define SYS_write	64
#define SYS_exit	93
#define SYS_reboot	142

/* backslashxx extends the reboot request with root-only commands, kernel/downstream/toolkit.h. The
 * id goes where the install magic goes, the new appid in the third argument. */
#define TOOLKIT_CHANGE_MANAGER_UID	10006

typedef __INTPTR_TYPE__ sysarg;

static sysarg sys4(sysarg n, sysarg a, sysarg b, sysarg c, sysarg d)
{
	register sysarg x0 __asm__("x0") = a;
	register sysarg x1 __asm__("x1") = b;
	register sysarg x2 __asm__("x2") = c;
	register sysarg x3 __asm__("x3") = d;
	register sysarg x8 __asm__("x8") = n;

	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3)
			 : "memory", "cc");
	return x0;
}

/* The compiler emits this call for the zero initialised profile. The empty asm keeps the
 * loop from being turned back into a call to itself. */
void *memset(void *dst, int c, unsigned long n)
{
	unsigned char *p = dst;

	while (n--) {
		*p++ = (unsigned char)c;
		__asm__ volatile("" ::: "memory");
	}
	return dst;
}

static unsigned long str_len(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static int str_eq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

static void put(const char *s)
{
	sys4(SYS_write, 1, (sysarg)s, (sysarg)str_len(s), 0);
}

static void put_num(long v)
{
	char buf[24];
	int i = sizeof(buf) - 1;
	unsigned long u = v < 0 ? -(unsigned long)v : (unsigned long)v;

	buf[i] = '\0';
	do {
		buf[--i] = '0' + u % 10;
		u /= 10;
	} while (u);
	if (v < 0)
		buf[--i] = '-';
	put(buf + i);
}

static int parse_uid(const char *s, __u32 *uid)
{
	__u32 v = 0;

	if (!*s)
		return -1;
	for (; *s; s++) {
		if (*s < '0' || *s > '9')
			return -1;
		v = v * 10 + (*s - '0');
	}
	*uid = v;
	return 0;
}

static void copy_str(char *dst, const char *src, unsigned long max)
{
	unsigned long i;

	for (i = 0; i + 1 < max && src[i]; i++)
		dst[i] = src[i];
	dst[i] = '\0';
}

/* The kernel part answers by writing the fd to the fourth argument. What reboot(2) itself
 * returns is the result of the real call, EINVAL for these magic numbers, and says nothing. */
static int open_fd(void)
{
	int fd = -1;

	sys4(SYS_reboot, KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, (sysarg)&fd);
	return fd < 0 ? -19 : fd;	/* ENODEV: no KernelSU answered */
}

static int report(const char *cmd, long rc, long value)
{
	put("ksuctl: ");
	put(cmd);
	put(" rc=");
	put_num(rc);
	put(" value=");
	put_num(value);
	put("\n");
	return rc < 0 ? (int)-rc : 0;
}

static int set_profile(int fd, __u32 uid, const char *mode)
{
	struct app_profile p = { 0 };
	char key[32] = "ksuctl.uid.";
	unsigned long n = str_len(key);

	if (!str_eq(mode, "allow") && !str_eq(mode, "deny") && !str_eq(mode, "keep"))
		return -1;

	p.version = KSU_APP_PROFILE_VER;
	p.curr_uid = uid;
	{
		char digits[12];
		int i = sizeof(digits) - 1;
		__u32 u = uid;

		digits[i] = '\0';
		do {
			digits[--i] = '0' + u % 10;
			u /= 10;
		} while (u);
		copy_str(key + n, digits + i, sizeof(key) - n);
	}
	copy_str(p.key, key, sizeof(p.key));

	if (str_eq(mode, "allow")) {
		p.allow_su = true;
		p.rp_config.use_default = false;
		p.rp_config.profile.uid = 0;
		p.rp_config.profile.gid = 0;
		p.rp_config.profile.capabilities.effective = ~0ULL;
		p.rp_config.profile.capabilities.permitted = ~0ULL;
		copy_str(p.rp_config.profile.selinux_domain, "u:r:su:s0",
			 sizeof(p.rp_config.profile.selinux_domain));
	} else {
		p.nrp_config.use_default = false;
		p.nrp_config.profile.umount_modules = str_eq(mode, "deny");
	}
	return report("profile", sys4(SYS_ioctl, fd, KSU_IOCTL_SET_APP_PROFILE, (sysarg)&p, 0), 0);
}

static int ksuctl_main(int argc, char **argv)
{
	const char *op = argc > 1 ? argv[1] : "";
	const char *arg = argc > 2 ? argv[2] : "";
	__u32 uid;
	int fd, rc;

	if (!str_eq(op, "event") && !str_eq(op, "umount") && !str_eq(op, "granted") &&
	    !str_eq(op, "profile") && !str_eq(op, "manager-toolkit")) {
		put("usage: ksuctl event|umount|granted|profile|manager-toolkit ...\n");
		return 2;
	}

	if (str_eq(op, "manager-toolkit")) {
		/* On success the kernel writes the pointer back to itself. */
		unsigned long long reply = 0;

		if (parse_uid(arg, &uid)) {
			put("usage: ksuctl manager-toolkit UID\n");
			return 2;
		}
		sys4(SYS_reboot, KSU_INSTALL_MAGIC1, TOOLKIT_CHANGE_MANAGER_UID, uid, (sysarg)&reply);
		return report("manager-toolkit", 0, reply == (unsigned long long)(sysarg)&reply);
	}

	fd = open_fd();
	if (fd < 0)
		return report("open", fd, 0);

	if (str_eq(op, "event")) {
		struct ksu_report_event_cmd cmd;

		if (str_eq(arg, "post-fs-data"))
			cmd.event = EVENT_POST_FS_DATA;
		else if (str_eq(arg, "boot-completed"))
			cmd.event = EVENT_BOOT_COMPLETED;
		else {
			put("usage: ksuctl event post-fs-data|boot-completed\n");
			return 2;
		}
		return report("event", sys4(SYS_ioctl, fd, KSU_IOCTL_REPORT_EVENT, (sysarg)&cmd, 0), 0);
	}

	if (parse_uid(arg, &uid)) {
		put("usage: ksuctl umount|granted|profile UID ...\n");
		return 2;
	}

	if (str_eq(op, "umount")) {
		struct ksu_uid_should_umount_cmd cmd = { .uid = uid };
		long rc = sys4(SYS_ioctl, fd, KSU_IOCTL_UID_SHOULD_UMOUNT, (sysarg)&cmd, 0);

		return report("umount", rc, cmd.should_umount);
	}

	if (str_eq(op, "granted")) {
		struct ksu_uid_granted_root_cmd cmd = { .uid = uid };
		long rc = sys4(SYS_ioctl, fd, KSU_IOCTL_UID_GRANTED_ROOT, (sysarg)&cmd, 0);

		return report("granted", rc, cmd.granted);
	}

	rc = argc < 4 ? -1 : set_profile(fd, uid, argv[3]);
	if (rc < 0) {
		put("usage: ksuctl profile UID allow|deny|keep\n");
		return 2;
	}
	return rc;
}

__asm__(
".text\n"
".global _start\n"
".type _start,%function\n"
"_start:\n"
"	mov	x29, #0\n"
"	ldr	x0, [sp]\n"
"	add	x1, sp, #8\n"
"	bl	ksuctl_entry\n"
"	mov	x8, #93\n"
"	svc	#0\n"
);

int ksuctl_entry(long argc, char **argv)
{
	return ksuctl_main((int)argc, argv);
}
