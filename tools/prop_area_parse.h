// SPDX-License-Identifier: GPL-2.0
/*
 * prop_area_parse.h: read-only reader for bionic's /dev/__properties__ trie.
 *
 * bionic lays every property area out the same way it has since Android 8 (property
 * context split): a 128-byte prop_area header
 *
 *     uint32 bytes_used; atomic uint32 serial; uint32 magic("PROP"); uint32 version; uint32 reserved[28];
 *
 * followed at offset 128 by a trie of prop_bt nodes
 *
 *     uint32 namelen; atomic uint32 prop; atomic uint32 left; atomic uint32 right; atomic uint32 children; char name[];
 *
 * where every non-zero field is a byte offset from the data area (offset 128).  A property name
 * is matched one dot-separated segment at a time: descend into the current node's `children`,
 * binary-search that sibling list by (namelen, bytes) via left/right, repeat for the next segment.
 * A leaf's `prop` offset points at a prop_info whose first word is the per-property serial that
 * bionic's __system_property_wait() futexes on.
 *
 * This header is the exact offset math, with nothing that needs a libc or a syscall, so the
 * freestanding susfs_propwait daemon and its host unit test share one implementation and the
 * parsing is exercised off-device.  Every offset is bounds-checked against the mapping size
 * because a reader must never fault on a value another process writes.
 */
#ifndef PROP_AREA_PARSE_H
#define PROP_AREA_PARSE_H

/* 32-bit on every target this builds for (arm64/x86_64 LP64, Windows LLP64, arm ILP32), and kept
 * local so the freestanding daemon needs no libc <stdint.h> / versioned sysroot. */
typedef unsigned int pa_u32;

#define PA_MAGIC    0x504f5250u	/* "PROP" */
#define PA_VERSION  0xfc6ed0abu
#define PA_DATA_OFF 128u	/* sizeof(prop_area) header before data_ */
#define PB_HDR      20u		/* namelen, prop, left, right, children */
#define PA_GUARD    1000000u	/* defang a cyclic/corrupt trie: cap the walk */

/* Little-endian unaligned 32-bit load: the areas are written by arm code and read here without
 * assuming the compiler may widen a misaligned access. */
static pa_u32 pa_ld32(const unsigned char *p)
{
	return (pa_u32)p[0] | ((pa_u32)p[1] << 8) |
	       ((pa_u32)p[2] << 16) | ((pa_u32)p[3] << 24);
}

/* bionic cmp_prop_name: a shorter segment sorts first, equal lengths compare byte by byte. */
static int pa_cmp(const char *a, pa_u32 alen, const unsigned char *b, pa_u32 blen)
{
	pa_u32 i;

	if (alen < blen)
		return -1;
	if (alen > blen)
		return 1;
	for (i = 0; i < alen; i++) {
		unsigned char ca = (unsigned char)a[i];

		if (ca != b[i])
			return ca < b[i] ? -1 : 1;
	}
	return 0;
}

/* A node at data offset @off is usable only if its header, name and the name's NUL all land inside
 * the @size-byte mapping.  Offset 0 is the null link (and the root's own slot), never a sibling. */
static int pa_node_ok(unsigned long size, pa_u32 off, pa_u32 namelen)
{
	unsigned long base = (unsigned long)PA_DATA_OFF + off;

	if (off == 0)
		return 0;
	if (base < PA_DATA_OFF)
		return 0;	/* offset wrapped */
	if (base + PB_HDR < base)
		return 0;
	if (base + PB_HDR + (unsigned long)namelen + 1 > size)
		return 0;
	return 1;
}

/* Binary-search one sibling list (the subtree rooted at byte offset @off) for segment @name. */
static pa_u32 pa_find_bt(const unsigned char *base, unsigned long size,
			   pa_u32 off, const char *name, pa_u32 namelen)
{
	pa_u32 guard = 0;

	while (off != 0) {
		const unsigned char *node = base + PA_DATA_OFF + off;
		pa_u32 nlen;
		int c;

		if (++guard > PA_GUARD)
			return 0;
		if ((unsigned long)PA_DATA_OFF + off + PB_HDR > size)
			return 0;
		nlen = pa_ld32(node);
		if (!pa_node_ok(size, off, nlen))
			return 0;
		c = pa_cmp(name, namelen, node + PB_HDR, nlen);
		if (c == 0)
			return off;
		off = pa_ld32(node + (c < 0 ? 8 : 12));	/* left : right */
	}
	return 0;
}

/* Byte offset (from the data area) of the prop_info for @name, or 0 when the area does not hold it.
 * The caller reads the prop_info's serial at `base + PA_DATA_OFF + offset`. */
static pa_u32 pa_find_prop_offset(const unsigned char *base, unsigned long size, const char *name)
{
	pa_u32 cur = 0;	/* the root prop_bt sits at data offset 0 */
	const char *rem = name;
	const unsigned char *node;
	pa_u32 po;

	if (size < (unsigned long)PA_DATA_OFF + PB_HDR)
		return 0;
	if (pa_ld32(base + 8) != PA_MAGIC)
		return 0;

	for (;;) {
		const char *dot = rem;
		pa_u32 seglen, children, match;

		while (*dot && *dot != '.')
			dot++;
		seglen = (pa_u32)(dot - rem);
		if ((unsigned long)PA_DATA_OFF + cur + PB_HDR > size)
			return 0;
		node = base + PA_DATA_OFF + cur;
		children = pa_ld32(node + 16);
		if (children == 0)
			return 0;
		match = pa_find_bt(base, size, children, rem, seglen);
		if (match == 0)
			return 0;
		cur = match;
		if (*dot == 0)
			break;
		rem = dot + 1;
	}

	node = base + PA_DATA_OFF + cur;
	po = pa_ld32(node + 4);	/* prop_info offset */
	if (po == 0)
		return 0;
	if ((unsigned long)PA_DATA_OFF + po + 4 > size)
		return 0;	/* serial word must be readable */
	return po;
}

#endif /* PROP_AREA_PARSE_H */
