// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_propwait: block on one Android system property and run a shell guard on every change.
 *
 * Why this exists: Xiaomi's /system_ext/bin/adb_root runs adbd as root under its own init service,
 * so the stock "adbd" service stays reported stopped while adbd is in fact live.  init OWNS
 * init.svc.adbd and rewrites it on every adbd service transition, so a one-shot fix at boot cannot
 * hold across an adb toggle.  This daemon watches the property and re-runs the guard whenever init
 * touches it, event driven: it blocks in a futex and wakes only when the value actually changes, so
 * it costs nothing while idle and never polls.
 *
 * How the wait works: bionic publishes every property in /dev/__properties__ as a per-context
 * memory area shared with every process, and __system_property_wait() futexes on a per-property
 * serial word that the writer bumps.  This reaches into that same shared mapping, finds the
 * property's serial (prop_area_parse.h), and FUTEX_WAITs on it, the exact mechanism resetprop and
 * bionic use, with no bionic, no NDK and no libc: freestanding -nostdlib -static-pie with raw svc.
 *
 * On each wake it forks /system/bin/sh <guard> so the policy (is adbd really up, correct the
 * property) stays in an auditable shell script, then waits for that child before blocking again, so
 * no child is left unreaped and a burst of changes collapses into one guard run.
 *
 * Build (same freestanding shape and clang as the module's other userspace tools):
 *     clang --target=aarch64-linux-gnu -O2 -nostdlib -static-pie \
 *           -fno-stack-protector -fno-builtin -fuse-ld=lld -Wl,-e,_start \
 *           -o susfs_propwait tools/susfs_propwait.c
 *
 * Usage: susfs_propwait <property-name> <guard-script-path>
 */

#include "prop_area_parse.h"

#define SYS_openat     56
#define SYS_close      57
#define SYS_getdents64 61
#define SYS_write      64
#define SYS_nanosleep  101
#define SYS_fstat      80
#define SYS_futex      98
#define SYS_munmap     215
#define SYS_clone      220
#define SYS_execve     221
#define SYS_mmap       222
#define SYS_wait4      260
#define SYS_exit_group 94

#define AT_FDCWD       -100
#define O_RDONLY       0
#define O_DIRECTORY    040000
#define O_CLOEXEC      02000000
#define PROT_READ      1
#define MAP_SHARED     1
#define FUTEX_WAIT     0
#define SIGCHLD        17

#define PROP_DIR       "/dev/__properties__"
#define SERIAL_FILE    PROP_DIR "/properties_serial"
#define SHELL          "/system/bin/sh"

static long syscall6(long n, long a0, long a1, long a2, long a3, long a4, long a5)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a0;
	register long x1 __asm__("x1") = a1;
	register long x2 __asm__("x2") = a2;
	register long x3 __asm__("x3") = a3;
	register long x4 __asm__("x4") = a4;
	register long x5 __asm__("x5") = a5;

	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
			 : "memory", "cc");
	return x0;
}

#define sys1(n, a)                syscall6((n), (long)(a), 0, 0, 0, 0, 0)
#define sys2(n, a, b)             syscall6((n), (long)(a), (long)(b), 0, 0, 0, 0)
#define sys3(n, a, b, c)          syscall6((n), (long)(a), (long)(b), (long)(c), 0, 0, 0)
#define sys4(n, a, b, c, d)       syscall6((n), (long)(a), (long)(b), (long)(c), (long)(d), 0, 0)
#define sys6(n, a, b, c, d, e, f) syscall6((n), (long)(a), (long)(b), (long)(c), (long)(d), (long)(e), (long)(f))

static int failed(long r)
{
	return (unsigned long)r >= (unsigned long)-4095;
}

static unsigned long slen(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void logline(const char *s)
{
	/* Best-effort breadcrumb on stdout, service.sh redirects it to the module log. */
	sys3(SYS_write, 1, (long)s, (long)slen(s));
}

/* Join PROP_DIR, '/', @name into @dst (caller guarantees PATH_MAX). */
static void join(char *dst, const char *name)
{
	const char *p = PROP_DIR "/";
	char *o = dst;

	while (*p)
		*o++ = *p++;
	while (*name)
		*o++ = *name++;
	*o = 0;
}

/* mmap a property area file whole, returns 0 on any failure, else the mapping and its size. */
static unsigned char *map_file(const char *path, unsigned long *out_size)
{
	char st[128];
	long fd, map, size;

	fd = sys4(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
	if (failed(fd))
		return 0;
	if (failed(sys2(SYS_fstat, fd, st))) {
		sys1(SYS_close, fd);
		return 0;
	}
	size = *(long *)(st + 48);		/* struct stat::st_size on arm64 */
	if (size < (long)PA_DATA_OFF) {
		sys1(SYS_close, fd);
		return 0;
	}
	map = sys6(SYS_mmap, 0, size, PROT_READ, MAP_SHARED, fd, 0);
	sys1(SYS_close, fd);			/* the mapping outlives the descriptor */
	if (failed(map))
		return 0;
	*out_size = (unsigned long)size;
	return (unsigned char *)map;
}

/* Find @prop across every context area in PROP_DIR.  Returns a pointer to its serial word (inside a
 * mapping kept live for the caller), or 0.  Non-matching areas are unmapped before moving on. */
static unsigned char *find_serial(const char *prop)
{
	char buf[4096];
	char path[256];
	long fd, n;

	fd = sys4(SYS_openat, AT_FDCWD, PROP_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
	if (failed(fd))
		return 0;

	while ((n = sys3(SYS_getdents64, fd, buf, sizeof(buf))) > 0) {
		long off = 0;

		while (off < n) {
			unsigned short reclen = *(unsigned short *)(buf + off + 16);
			const char *name = buf + off + 19;	/* linux_dirent64::d_name */
			unsigned long size;
			unsigned char *area;
			pa_u32 po;

			if (reclen == 0)
				break;			/* malformed record: never spin */
			off += reclen;
			/* Only the per-context areas (u:object_r:...:s0); this skips ., .., property_info
			 * and properties_serial, none of which start with "u:". */
			if (name[0] != 'u' || name[1] != ':')
				continue;
			join(path, name);
			area = map_file(path, &size);
			if (!area)
				continue;
			po = pa_find_prop_offset(area, size, prop);
			if (po) {
				sys1(SYS_close, fd);
				return area + PA_DATA_OFF + po;
			}
			sys2(SYS_munmap, area, size);
		}
	}
	sys1(SYS_close, fd);
	return 0;
}

/* The global serial bionic bumps on every property set, used only to wait for @prop to appear. */
static unsigned char *map_global_serial(void)
{
	unsigned long size;
	unsigned char *area = map_file(SERIAL_FILE, &size);

	if (!area)
		return 0;
	if (pa_ld32(area + 8) != PA_MAGIC) {
		sys2(SYS_munmap, area, size);
		return 0;
	}
	return area + 4;			/* prop_area::serial_ */
}

static void futex_wait(unsigned char *addr, pa_u32 val)
{
	/* Shared futex (no PRIVATE flag): the writer lives in init, another process, and wakes the
	 * same physical page.  A spurious or already-changed wake just re-reads and loops. */
	sys6(SYS_futex, addr, FUTEX_WAIT, val, 0, 0, 0);
}

/* fork + exec `SHELL <script>`, inheriting @envp, and reap the child before returning. */
static void run_guard(const char *script, char **envp)
{
	long pid = sys6(SYS_clone, SIGCHLD, 0, 0, 0, 0, 0);

	if (failed(pid))
		return;				/* out of resources: skip this event, try next */
	if (pid == 0) {
		char *argv[3];

		argv[0] = (char *)SHELL;
		argv[1] = (char *)script;
		argv[2] = 0;
		sys3(SYS_execve, SHELL, argv, envp);
		sys1(SYS_exit_group, 127);	/* exec failed: never fall back into the watch loop */
	}
	sys4(SYS_wait4, pid, 0, 0, 0);
}

int pw_main(long argc, char **argv)
{
	const char *prop, *script;
	char **envp;
	unsigned char *serial;
	pa_u32 last;

	if (argc < 3) {
		logline("susfs_propwait: usage: susfs_propwait <property> <guard-script>\n");
		return 2;
	}
	prop = argv[1];
	script = argv[2];
	envp = argv + argc + 1;			/* the environ vector follows argv's NULL terminator */

	logline("susfs_propwait: start\n");
	/* Correct the current state immediately, before the first change arrives. */
	run_guard(script, envp);

	serial = find_serial(prop);
	if (!serial) {
		/* The property is not published yet: wait on the global serial and rescan until it
		 * appears.  init publishes init.svc.* for every known service at boot, so in practice
		 * this is reached only if the daemon starts extremely early. */
		unsigned char *gserial = map_global_serial();

		logline("susfs_propwait: property absent, waiting for it to appear\n");
		while (!serial) {
			if (gserial) {
				futex_wait(gserial, pa_ld32(gserial));
			} else {
				struct { long s; long ns; } ts = { 1, 0 };

				sys2(SYS_nanosleep, &ts, 0);	/* no serial area: never busy-spin */
			}
			serial = find_serial(prop);
		}
		run_guard(script, envp);
	}

	logline("susfs_propwait: watching\n");
	last = pa_ld32(serial);
	for (;;) {
		futex_wait(serial, last);
		if (pa_ld32(serial) == last)
			continue;		/* spurious wake: value unchanged */
		run_guard(script, envp);
		last = pa_ld32(serial);		/* the guard's own write may have bumped it */
	}
}

__asm__(
".text\n"
".global _start\n"
".type _start,%function\n"
"_start:\n"
"	mov	x29, #0\n"
"	ldr	x0, [sp]\n"		/* argc */
"	add	x1, sp, #8\n"		/* argv */
"	bl	pw_main\n"
"	mov	x8, #94\n"		/* exit_group */
"	svc	#0\n"
);
