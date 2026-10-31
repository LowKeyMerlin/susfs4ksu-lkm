// SPDX-License-Identifier: GPL-2.0-only
/*
 * kstat_probe - what statfs and fstatfs answer for a path, as "name=value" lines. Used by the smoke
 * VM, never shipped. One source for both ABIs, like prio_probe.c, since the 32-bit tasks reach
 * statfs64 and fstatfs64 through the AArch32 table.
 *
 *   kstat_probe statfs PATH    statfs of PATH
 *   kstat_probe fstatfs PATH   fstatfs of a descriptor opened on PATH
 *   kstat_probe errors PATH    the results of calls that must fail
 *   kstat_probe inotify PATH   the fdinfo of an inotify descriptor watching PATH
 *   kstat_probe mntid PATH     the 64-bit unique mount id statx gives for PATH
 *   kstat_probe listmount N [PARENT]
 *                              every id listmount gives under PARENT (default the root), N ids
 *                              per call, paging as a caller does
 *   kstat_probe statmount ID   statmount of one unique mount id
 *
 * Prints rc (the syscall result), blocks and bsize. Blocks tells two filesystems apart, which is
 * all a rule has to change.
 */

#if defined(__aarch64__)
#define NR_EXIT		93
#define NR_WRITE	64
#define NR_OPENAT	56
#define NR_CLOSE	57
#define NR_STATFS	43
#define NR_FSTATFS	44
#define NR_READ		63
#define NR_INOTIFY_INIT1	26
#define NR_INOTIFY_ADD	27
#define NR_STATX	291
#define SIZE_ARG	0
#define STRUCT_LEN	120	/* sizeof(struct statfs) */
/* struct statfs of asm-generic: f_type, f_bsize, f_blocks as longs. */
#define BSIZE_OFF	8
#define BLOCKS_OFF	16
#elif defined(__arm__)
#define NR_EXIT		1
#define NR_WRITE	4
#define NR_OPEN		5
#define NR_CLOSE	6
#define NR_STATFS	266	/* statfs64 */
#define NR_FSTATFS	267	/* fstatfs64 */
#define NR_READ		3
#define NR_INOTIFY_INIT1	360
#define NR_INOTIFY_ADD	317
#define NR_STATX	397
#define SIZE_ARG	84	/* sizeof(struct statfs64) of the EABI, which the call checks */
#define STRUCT_LEN	84
#define BSIZE_OFF	4
#define BLOCKS_OFF	8
#else
#error "aarch64 and arm only"
#endif

/* The two mount syscalls have one number on both ABIs. */
#define NR_STATMOUNT	457
#define NR_LISTMOUNT	458
#define STATX_MNT_ID_UNIQUE	0x4000
#define STX_MNT_ID_OFF	144	/* struct statx.stx_mnt_id */
#define MNT_ID_REQ_SIZE_VER0	24
#define LSMT_ROOT	0xffffffffffffffffULL
#define STATMOUNT_MNT_BASIC	0x2
#define SM_MNT_ID_OFF	40	/* struct statmount.mnt_id */
#define LM_MAX_IDS	4096

/* O_RDONLY | O_DIRECTORY, which arm and arm64 number 040000 and not as asm-generic does. */
#define O_DIRECTORY_RDONLY	040000
/* O_PATH is 010000000 on arm and arm64 alike (asm-generic). */
#define O_PATH_FLAG		010000000

static long sys5(long nr, long a, long b, long c, long d, long e)
{
#if defined(__aarch64__)
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
			 : "memory", "cc");
	return x0;
#else
	register long r7 __asm__("r7") = nr;
	register long r0 __asm__("r0") = a;
	register long r1 __asm__("r1") = b;
	register long r2 __asm__("r2") = c;
	register long r3 __asm__("r3") = d;
	register long r4 __asm__("r4") = e;

	__asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4)
			 : "memory", "cc");
	return r0;
#endif
}

static long sys(long nr, long a, long b, long c)
{
	return sys5(nr, a, b, c, 0, 0);
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
	sys(NR_WRITE, 1, (long)s, (long)length(s));
}

static int same(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

/* "key=value\n", the value signed. */
static void report(const char *key, long long value)
{
	char line[64];
	char digits[24];
	unsigned long long u = value < 0 ? 0ULL - (unsigned long long)value : (unsigned long long)value;
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

static long open_path(const char *path, long flags)
{
#if defined(__aarch64__)
	return sys(NR_OPENAT, -100, (long)path, flags);
#else
	return sys(NR_OPEN, (long)path, flags, 0);
#endif
}

static long open_dir(const char *path)
{
	return open_path(path, O_DIRECTORY_RDONLY);
}

/* Watch PATH, then print what /proc/self/fdinfo says of the descriptor: the "inotify wd: ino: sdev:"
 * line is where a rule on PATH shows. */
static int inotify_fdinfo(const char *path)
{
	static char text[1024];
	char name[32] = "/proc/self/fdinfo/";
	unsigned long i = length(name);
	long fd, wd, n, f, v;
	char digits[12];
	int k = 0;

	fd = sys(NR_INOTIFY_INIT1, 0, 0, 0);
	if (fd < 0) {
		report("inotify_init", fd);
		return 1;
	}
	wd = sys(NR_INOTIFY_ADD, fd, (long)path, 0xfff);
	if (wd < 0) {
		report("inotify_add", wd);
		return 1;
	}
	v = fd;
	do {
		digits[k++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (k)
		name[i++] = digits[--k];
	name[i] = 0;
	f = open_path(name, 0);
	if (f < 0) {
		report("fdinfo_open", f);
		return 1;
	}
	n = sys(NR_READ, f, (long)text, (long)sizeof(text) - 1);
	if (n <= 0) {
		report("fdinfo_read", n);
		return 1;
	}
	text[n] = 0;
	say(text);
	return 0;
}

static unsigned long long parse_u64(const char *s)
{
	unsigned long long v = 0;

	while (*s >= '0' && *s <= '9')
		v = v * 10 + (unsigned long long)(*s++ - '0');
	return v;
}

/* struct mnt_id_req { __u32 size; __u32 spare; __u64 mnt_id; __u64 param; __u64 mnt_ns_id; }.
 * mnt_id is the target for statmount and the parent for listmount; param is the mask for statmount
 * and the paging cursor (last id seen) for listmount. */
struct mnt_id_req {
	unsigned int size;
	unsigned int spare;
	unsigned long long mnt_id;
	unsigned long long param;
	unsigned long long mnt_ns_id;
};

/* The 64-bit unique mount id statx reports for PATH, the id listmount/statmount name a mount by. */
static long mntid(const char *path, unsigned long long *out)
{
	static unsigned char buf[256] __attribute__((aligned(8)));
	long rc = sys5(NR_STATX, -100, (long)path, 0, STATX_MNT_ID_UNIQUE, (long)buf);

	if (rc == 0)
		*out = *(unsigned long long *)(buf + STX_MNT_ID_OFF);
	return rc;
}

/* Page through listmount under PARENT (LSMT_ROOT lists the caller's root), NR ids per call, exactly
 * as a real caller does: stop on a return <= 0 and resume after the last id of the previous page.
 * Prints every id it is given so the test can assert a marked id never appears. */
static int listmount_pages(unsigned long long parent, long nr)
{
	static unsigned long long ids[LM_MAX_IDS];
	struct mnt_id_req req = { .size = MNT_ID_REQ_SIZE_VER0, .mnt_id = parent, .param = 0 };
	long total = 0;

	if (nr < 1 || nr > LM_MAX_IDS)
		nr = 1;
	for (;;) {
		long got = sys5(NR_LISTMOUNT, (long)&req, (long)ids, nr, 0, 0), i;

		if (got < 0) {
			report("rc", got);
			return 1;
		}
		for (i = 0; i < got; i++) {
			report("id", (long long)ids[i]);
			req.param = ids[i];	/* resume after the last id seen */
		}
		total += got;
		if (got < nr)			/* a short (or empty) page is the end */
			break;
	}
	report("count", total);
	return 0;
}

/* One listmount call over a buffer of NR slots filled with a sentinel, then every slot the call did
 * NOT report (index >= the returned count) that holds ID: a hidden id left behind by compaction.
 * listmount_pages() only prints the reported slots, so it cannot see this. */
#define LM_SENTINEL 0xdeadbeefdeadbeefULL
static int listmount_tail(long nr, unsigned long long id)
{
	static unsigned long long ids[LM_MAX_IDS];
	struct mnt_id_req req = { .size = MNT_ID_REQ_SIZE_VER0, .mnt_id = LSMT_ROOT, .param = 0 };
	long got, i, hits = 0;

	if (nr < 1 || nr > LM_MAX_IDS)
		nr = 1;
	for (i = 0; i < nr; i++)
		ids[i] = LM_SENTINEL;
	got = sys5(NR_LISTMOUNT, (long)&req, (long)ids, nr, 0, 0);
	report("rc", got);
	if (got < 0)
		return 1;
	for (i = 0; i < got; i++)
		if (ids[i] == id)
			report("reported_hidden", i);
	for (i = got; i < nr; i++)
		if (ids[i] == id)
			hits++;
	report("tail_hidden", hits);
	return 0;
}

/* statmount of one unique id. Prints rc and, on success, the mnt_id the kernel wrote back, so the
 * test can tell a real answer from a hidden one (which comes out as an error or a zeroed buffer). */
static int statmount_one(unsigned long long id)
{
	/* static, so zero on the one call a process makes */
	static unsigned char buf[1024] __attribute__((aligned(8)));
	struct mnt_id_req req = { .size = MNT_ID_REQ_SIZE_VER0, .mnt_id = id,
				 .param = STATMOUNT_MNT_BASIC };
	long rc;

	rc = sys5(NR_STATMOUNT, (long)&req, (long)buf, (long)sizeof(buf), 0, 0);
	report("rc", rc);
	if (rc < 0)
		return 1;
	report("sm_mnt_id", (long long)*(unsigned long long *)(buf + SM_MNT_ID_OFF));
	return 0;
}

/* statfs or statfs64 of PATH into BUF, whichever this ABI has */
static long do_statfs(long path, long buf)
{
	return sys(NR_STATFS, path, SIZE_ARG ? SIZE_ARG : buf, SIZE_ARG ? buf : 0);
}

/* The calls that must fail, and how. The answer of a caller the rules apply to is built by the
 * module and not by the kernel, so each error the kernel gives has to be given the same way. */
static void errors(const char *path, void *buf)
{
	report("nullpath", do_statfs(0, (long)buf));
	report("badbuf", do_statfs((long)path, 1));
	report("missing", do_statfs((long)"/nonexistent-ks", (long)buf));
	report("badfd", sys(NR_FSTATFS, 9999, SIZE_ARG ? SIZE_ARG : (long)buf, SIZE_ARG ? (long)buf : 0));
#if defined(__arm__)
	/* statfs64 insists on the exact size of the struct */
	report("badsize", sys(NR_STATFS, (long)path, SIZE_ARG - 1, (long)buf));
#endif
}

long probe_main(long argc, char **argv)
{
	static unsigned char buf[128] __attribute__((aligned(8)));
	unsigned long long sum = 1469598103934665603ULL;
	unsigned long i;
	long rc, fd = -1;

	if (argc < 3) {
		say("usage: kstat_probe statfs|fstatfs|errors|inotify|mntid|listmount|statmount PATH\n");
		return 2;
	}
	if (same(argv[1], "inotify"))
		return inotify_fdinfo(argv[2]);
	if (same(argv[1], "mntid")) {
		unsigned long long id = 0;
		long r = mntid(argv[2], &id);

		report("rc", r);
		if (r == 0)
			report("mntid", (long long)id);
		return r ? 1 : 0;
	}
	if (same(argv[1], "listmount")) {
		unsigned long long parent = argc > 3 ? parse_u64(argv[3]) : LSMT_ROOT;

		return listmount_pages(parent, (long)parse_u64(argv[2]));
	}
	if (same(argv[1], "listmount_tail"))	/* listmount_tail N ID */
		return argc > 3 ? listmount_tail((long)parse_u64(argv[2]), parse_u64(argv[3])) : 2;
	if (same(argv[1], "statmount"))
		return statmount_one(parse_u64(argv[2]));
	if (same(argv[1], "errors")) {
		errors(argv[2], buf);
		return 0;
	}
	if (same(argv[1], "statfs")) {
		rc = sys(NR_STATFS, (long)argv[2], SIZE_ARG ? SIZE_ARG : (long)buf, SIZE_ARG ? (long)buf : 0);
	} else if (same(argv[1], "fstatfs_opath")) {
		/* fs/statfs.c fd_statfs() takes fdget_raw(), so an O_PATH descriptor is a legal argument */
		fd = open_path(argv[2], O_PATH_FLAG | O_DIRECTORY_RDONLY);
		if (fd < 0) {
			report("rc", fd);
			return 1;
		}
		rc = sys(NR_FSTATFS, fd, SIZE_ARG ? SIZE_ARG : (long)buf, SIZE_ARG ? (long)buf : 0);
		sys(NR_CLOSE, fd, 0, 0);
	} else if (same(argv[1], "fstatfs")) {
		fd = open_dir(argv[2]);
		if (fd < 0) {
			report("rc", fd);
			return 1;
		}
		rc = sys(NR_FSTATFS, fd, SIZE_ARG ? SIZE_ARG : (long)buf, SIZE_ARG ? (long)buf : 0);
		sys(NR_CLOSE, fd, 0, 0);
	} else {
		say("unknown mode\n");
		return 2;
	}
	report("rc", rc);
	if (rc)
		return 1;
#if defined(__aarch64__)
	report("bsize", *(long *)(buf + BSIZE_OFF));
	report("blocks", *(long long *)(buf + BLOCKS_OFF));
#else
	report("bsize", *(unsigned int *)(buf + BSIZE_OFF));
	report("blocks", *(long long *)(buf + BLOCKS_OFF));
#endif
	/* every byte of the answer, so a field the module fills differently from the kernel shows */
	for (i = 0; i < STRUCT_LEN; i++)
		sum = (sum ^ buf[i]) * 1099511628211ULL;
	report("csum", (long long)(sum >> 1));
	return 0;
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
