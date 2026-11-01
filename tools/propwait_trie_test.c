// SPDX-License-Identifier: GPL-2.0
/*
 * Host test for prop_area_parse.h.  It builds a property area the way bionic's write path does -
 * allocate a root node, then for each property walk the dot-separated name creating a child node
 * and a BST sibling per segment, and then checks that the read path in the header finds exactly
 * the leaves that were added, at the offset the builder recorded.  The builder and the reader are
 * independent code, so a wrong field offset in either one makes a case fail.
 *
 * Build and run on the host (no device, no cross toolchain):
 *     cc -O1 -Wall -Wextra -o /tmp/propwait_trie_test tools/propwait_trie_test.c && /tmp/propwait_trie_test
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "prop_area_parse.h"

#define AREA_BYTES 131072u

struct area {
	unsigned char buf[AREA_BYTES];
	uint32_t used;		/* bytes allocated in the data region (offset from data_) */
};

static unsigned char *data(struct area *a)
{
	return a->buf + PA_DATA_OFF;
}

static uint32_t rd(struct area *a, uint32_t off)
{
	return pa_ld32(data(a) + off);
}

static void wr(struct area *a, uint32_t off, uint32_t v)
{
	unsigned char *p = data(a) + off;

	p[0] = (unsigned char)v;
	p[1] = (unsigned char)(v >> 8);
	p[2] = (unsigned char)(v >> 16);
	p[3] = (unsigned char)(v >> 24);
}

static uint32_t roundup4(uint32_t n)
{
	return (n + 3u) & ~3u;
}

static uint32_t alloc(struct area *a, uint32_t n)
{
	uint32_t off = a->used;

	a->used += roundup4(n);
	return off;
}

static uint32_t new_bt(struct area *a, const char *seg, uint32_t seglen)
{
	uint32_t off = alloc(a, PB_HDR + seglen + 1);

	wr(a, off, seglen);		/* namelen */
	memcpy(data(a) + off + PB_HDR, seg, seglen);
	data(a)[off + PB_HDR + seglen] = 0;
	return off;
}

static uint32_t new_info(struct area *a, uint32_t serial)
{
	uint32_t off = alloc(a, 4 + 92 + 1);	/* serial + value[92] + name[] */

	wr(a, off, serial);		/* prop_info.serial */
	return off;
}

static void area_init(struct area *a)
{
	memset(a->buf, 0, sizeof(a->buf));
	a->buf[8] = 0x50; a->buf[9] = 0x52; a->buf[10] = 0x4f; a->buf[11] = 0x50;	/* "PROP" */
	a->buf[12] = 0xab; a->buf[13] = 0xd0; a->buf[14] = 0x6e; a->buf[15] = 0xfc;	/* version */
	a->used = 0;
	(void)new_bt(a, "", 0);		/* the root prop_bt owns data offset 0 */
}

/* Find or create the child of node @parent matching @seg, inserting into its left/right BST. */
static uint32_t descend(struct area *a, uint32_t parent, const char *seg, uint32_t seglen)
{
	uint32_t root = rd(a, parent + 16);	/* children */

	if (root == 0) {
		uint32_t node = new_bt(a, seg, seglen);

		wr(a, parent + 16, node);
		return node;
	}
	for (;;) {
		uint32_t nlen = rd(a, root);
		int c = pa_cmp(seg, seglen, data(a) + root + PB_HDR, nlen);
		uint32_t link;

		if (c == 0)
			return root;
		link = (c < 0) ? rd(a, root + 8) : rd(a, root + 12);
		if (link != 0) {
			root = link;
			continue;
		}
		{
			uint32_t node = new_bt(a, seg, seglen);

			wr(a, root + (c < 0 ? 8 : 12), node);
			return node;
		}
	}
}

/* Add a property, returns the offset of its prop_info (what the reader should return). */
static uint32_t add_prop(struct area *a, const char *name, uint32_t serial)
{
	uint32_t cur = 0;		/* root */
	const char *rem = name;

	for (;;) {
		const char *dot = rem;
		uint32_t pi;

		while (*dot && *dot != '.')
			dot++;
		cur = descend(a, cur, rem, (uint32_t)(dot - rem));
		if (*dot == 0) {
			pi = rd(a, cur + 4);
			if (pi == 0) {
				pi = new_info(a, serial);
				wr(a, cur + 4, pi);
			}
			return pi;
		}
		rem = dot + 1;
	}
}

static int fails;

static void expect_eq(const char *what, uint32_t got, uint32_t want)
{
	if (got == want) {
		printf("ok   %-40s = %u\n", what, got);
	} else {
		printf("FAIL %-40s got %u want %u\n", what, got, want);
		fails++;
	}
}

int main(void)
{
	static struct area a;
	uint32_t adbd, adb_root, console, bugreport;

	area_init(&a);
	/* Insert out of sort order so the left/right BST actually branches. */
	console = add_prop(&a, "init.svc.console", 0x100);
	adbd = add_prop(&a, "init.svc.adbd", 0x200);
	adb_root = add_prop(&a, "init.svc.adb_root", 0x300);
	bugreport = add_prop(&a, "init.svc.bugreport", 0x400);
	(void)add_prop(&a, "ro.build.version.sdk", 0x500);
	(void)add_prop(&a, "sys.boot_completed", 0x600);

	/* Leaves resolve to the exact prop_info the builder placed. */
	expect_eq("find init.svc.adbd", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.adbd"), adbd);
	expect_eq("find init.svc.adb_root", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.adb_root"), adb_root);
	expect_eq("find init.svc.console", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.console"), console);
	expect_eq("find init.svc.bugreport", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.bugreport"), bugreport);
	expect_eq("find sys.boot_completed", pa_find_prop_offset(a.buf, AREA_BYTES, "sys.boot_completed") != 0, 1);

	/* Absent names, intermediate nodes and a sibling prefix all resolve to "not here". */
	expect_eq("absent init.svc.nope", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.nope"), 0);
	expect_eq("intermediate init.svc", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc"), 0);
	expect_eq("intermediate init", pa_find_prop_offset(a.buf, AREA_BYTES, "init"), 0);
	expect_eq("absent init.svc.adb", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.adb"), 0);

	/* The serial the reader points at is the one the builder wrote. */
	expect_eq("adbd serial readback", pa_ld32(a.buf + PA_DATA_OFF + adbd), 0x200);

	/* A wrong magic is refused, and a truncated mapping is walked without reading past its end. */
	a.buf[8] = 0;
	expect_eq("bad magic refused", pa_find_prop_offset(a.buf, AREA_BYTES, "init.svc.adbd"), 0);
	a.buf[8] = 0x50;
	expect_eq("truncated map refused", pa_find_prop_offset(a.buf, PA_DATA_OFF + 4, "init.svc.adbd"), 0);

	if (fails) {
		printf("\n%d case(s) failed\n", fails);
		return 1;
	}
	printf("\nall cases passed\n");
	return 0;
}
