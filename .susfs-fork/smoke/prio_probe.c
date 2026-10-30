// SPDX-License-Identifier: GPL-2.0-only
/*
 * prio_probe - what getpriority, setpriority, ioprio_get and ioprio_set answer for a uid, and a client
 * for the supercall that sets the priority uid filter. Used by the smoke VM, never shipped.
 *
 * Freestanding like tools/susfs_sc.c, which cannot be used here: the payload of the filter command is
 * 64 KiB and that client holds 8 KiB. One source for two ABIs, because the module wraps the syscall table
 * of the 32-bit tasks as well and that entry needs a caller of its own:
 *
 *   clang --target=aarch64-linux-gnu -O2 -nostdlib -static-pie -fno-stack-protector -fno-builtin \
 *         -fuse-ld=lld -Wl,-e,_start -o prio_probe prio_probe.c
 *   clang --target=armv7-linux-gnueabi -marm -O2 -nostdlib -static -fno-stack-protector -fno-builtin \
 *         -fuse-ld=lld -Wl,-e,_start -o prio_probe32 prio_probe.c
 *
 * Usage:
 *   prio_probe user WHO   the four calls about the uid WHO, as "name=result" lines. A result is what the
 *                         syscall returned: a value or a negated errno. ioprio_set_bad passes an invalid
 *                         class, which has to fail with EINVAL whatever the uid is.
 *   prio_probe pid WHO    the same two reads about the process WHO, which no filter touches.
 *   prio_probe set NAMES  (64-bit only) sends CMD_SUSFS_SET_PRIORITY_UID_FILTER with the list NAMES and
 *                         prints what the reboot call returned and the err the kernel wrote back, which
 *                         stays 126 when the kernel does not handle the command.
 *   prio_probe setfill    the same with a list that is not terminated inside the buffer.
 */

#define PRIO_PROCESS	0
#define PRIO_USER	2
#define IOPRIO_WHO_PROCESS	1
#define IOPRIO_WHO_USER	3
/* IOPRIO_PRIO_VALUE(class, data) is (class << 13) | data: best effort level 4, and class 7 (invalid). */
#define IOPRIO_BE_4	((2 << 13) | 4)
#define IOPRIO_BAD	(7 << 13)

#if defined(__aarch64__)
#define NR_EXIT		93
#define NR_WRITE	64
#define NR_REBOOT	142
#define NR_GETPRIORITY	141
#define NR_SETPRIORITY	140
#define NR_IOPRIO_SET	30
#define NR_IOPRIO_GET	31
#elif defined(__arm__)
#define NR_EXIT		1
#define NR_WRITE	4
#define NR_GETPRIORITY	96
#define NR_SETPRIORITY	97
#define NR_IOPRIO_SET	314
#define NR_IOPRIO_GET	315
#else
#error "aarch64 and arm only"
#endif

#define KSU_INSTALL_MAGIC1		0xDEADBEEF
#define SUSFS_MAGIC			0xFAFAFAFA
#define CMD_SET_PRIORITY_UID_FILTER	0x60030
#define APP_STR_BUF_SIZE		65535
/* struct st_susfs_priority_uid_filter: the string, then the int err, 4-byte aligned. */
#define PAYLOAD_SIZE			65540
#define ERR_OFFSET			65536
#define ERR_SEED			126

static long sys(long nr, long a, long b, long c, long d)
{
#if defined(__aarch64__)
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory", "cc");
	return x0;
#else
	register long r7 __asm__("r7") = nr;
	register long r0 __asm__("r0") = a;
	register long r1 __asm__("r1") = b;
	register long r2 __asm__("r2") = c;
	register long r3 __asm__("r3") = d;

	__asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3) : "memory", "cc");
	return r0;
#endif
}

static unsigned long length(const char *s)
{
	unsigned long n = 0;

	while (s[n])
		n++;
	return n;
}

static void say(const char *s)
{
	sys(NR_WRITE, 1, (long)s, (long)length(s), 0);
}

static int same(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

static long number(const char *s)
{
	long v = 0;

	while (*s >= '0' && *s <= '9')
		v = v * 10 + (*s++ - '0');
	return v;
}

/* "key=value\n", the value signed. */
static void report(const char *key, long value)
{
	char line[64];
	char digits[24];
	unsigned long u = value < 0 ? 0UL - (unsigned long)value : (unsigned long)value;
	unsigned long n = 0, i = 0;

	while (*key)
		line[i++] = *key++;
	line[i++] = '=';
	if (value < 0)
		line[i++] = '-';
	do {
		digits[n++] = (char)('0' + u % 10);
		u /= 10;
	} while (u);
	while (n)
		line[i++] = digits[--n];
	line[i++] = '\n';
	line[i] = 0;
	say(line);
}

#if defined(__aarch64__)
static char payload[PAYLOAD_SIZE] __attribute__((aligned(16)));

static void send_filter(void)
{
	long rc;

	*(int *)(payload + ERR_OFFSET) = ERR_SEED;
	rc = sys(NR_REBOOT, KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SET_PRIORITY_UID_FILTER, (long)payload);
	report("set_rc", rc);
	report("set_err", *(int *)(payload + ERR_OFFSET));
}
#endif

long probe_main(long argc, char **argv)
{
	long who;

	if (argc < 2) {
		say("usage: prio_probe user WHO | pid WHO | set NAMES | setfill\n");
		return 2;
	}
	who = argc > 2 ? number(argv[2]) : 0;

	if (same(argv[1], "user")) {
		report("getpriority", sys(NR_GETPRIORITY, PRIO_USER, who, 0, 0));
		report("setpriority", sys(NR_SETPRIORITY, PRIO_USER, who, 0, 0));
		report("ioprio_get", sys(NR_IOPRIO_GET, IOPRIO_WHO_USER, who, 0, 0));
		report("ioprio_set", sys(NR_IOPRIO_SET, IOPRIO_WHO_USER, who, IOPRIO_BE_4, 0));
		report("ioprio_set_bad", sys(NR_IOPRIO_SET, IOPRIO_WHO_USER, who, IOPRIO_BAD, 0));
		return 0;
	}
	if (same(argv[1], "pid")) {
		report("getpriority_pid", sys(NR_GETPRIORITY, PRIO_PROCESS, who, 0, 0));
		report("ioprio_get_pid", sys(NR_IOPRIO_GET, IOPRIO_WHO_PROCESS, who, 0, 0));
		return 0;
	}
#if defined(__aarch64__)
	if (same(argv[1], "set") && argc > 2) {
		unsigned long n = length(argv[2]);
		unsigned long i;

		if (n >= APP_STR_BUF_SIZE) {
			say("the list does not fit\n");
			return 2;
		}
		for (i = 0; i < n; i++)
			payload[i] = argv[2][i];
		send_filter();
		return 0;
	}
	if (same(argv[1], "setfill")) {
		unsigned long i;

		for (i = 0; i < APP_STR_BUF_SIZE; i++) {
			payload[i] = 'a';
			__asm__ volatile("" ::: "memory");
		}
		send_filter();
		return 0;
	}
#endif
	say("unknown mode\n");
	return 2;
}

#if defined(__aarch64__)
__asm__(
".text\n"
".global _start\n"
".type _start,%function\n"
"_start:\n"
"	mov	x29, #0\n"
"	ldr	x0, [sp]\n"
"	add	x1, sp, #8\n"
"	bl	probe_main\n"
"	mov	x8, #93\n"
"	svc	#0\n"
);
#else
__asm__(
".text\n"
".arm\n"
".global _start\n"
".type _start,%function\n"
"_start:\n"
"	mov	fp, #0\n"
"	ldr	r0, [sp]\n"
"	add	r1, sp, #4\n"
"	bl	probe_main\n"
"	mov	r7, #1\n"
"	svc	#0\n"
);
#endif
