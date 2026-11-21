/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * susfs_uid_filter.h: a set of app uids named by package, kept up to date as packages change.
 *
 * Two features use one: the getpriority filter hides the uids in its set, the sus_path filter lets
 * the uids in its set see the paths that are hidden from other apps. Each owns one struct
 * susfs_uid_filter. The engine reads /data/system/packages.list, turns package names into app ids
 * and keeps the result as an RCU bitmap, so a lookup is one bit test.
 */
#ifndef SUSFS_UID_FILTER_H
#define SUSFS_UID_FILTER_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/rcupdate.h>
#include <linux/bitmap.h>
#include <linux/cred.h>

#include "susfs_abi.h"

/* Every Android user has its own block of uids, the app id is the offset in it. */
#define SUSFS_UID_PER_USER_RANGE	100000

struct susfs_uid_bitmap {
	struct rcu_head rcu;
	DECLARE_BITMAP(bits, SUSFS_UID_FILTER_UID_NUM);
};

struct susfs_uid_filter {
	const char *name;		/* log prefix */
	bool lenient;			/* a package with no uid is skipped, not an error, when sent */
	struct susfs_uid_bitmap __rcu *bitmap;
	/* Under lock: the list as sent, its sender's credentials, and a counter that tells a refresh
	 * whether the list was replaced while it resolved. */
	struct mutex lock;
	char *names;
	const struct cred *cred;
	unsigned int gen;
	bool attached;
	struct list_head node;
};

/* Start following package changes for this filter. The first filter arms the d_move kprobe that
 * sees packages.list replaced; without it the list goes stale when an app is reinstalled, so a
 * failure is returned and the filter stays unusable. */
int susfs_uid_filter_attach(struct susfs_uid_filter *f);
/* Stop following and drop the set. Call it after every reader is gone. */
void susfs_uid_filter_detach(struct susfs_uid_filter *f);
/* The command: replace the set with the packages in a comma separated list, answer in *errp. */
void susfs_uid_filter_supercall(struct susfs_uid_filter *f, const char __user *strings,
				int __user *errp);

/* Is this app id (the uid modulo the per-user range) in the set? */
static inline bool susfs_uid_filter_has(struct susfs_uid_filter *f, uid_t app_id)
{
	struct susfs_uid_bitmap *bitmap;
	bool hit = false;

	if (app_id < SUSFS_UID_FILTER_MIN_UID || app_id > SUSFS_UID_FILTER_MAX_UID)
		return false;
	rcu_read_lock();
	bitmap = rcu_dereference(f->bitmap);
	if (bitmap)
		hit = test_bit(app_id - SUSFS_UID_FILTER_MIN_UID, bitmap->bits);
	rcu_read_unlock();
	return hit;
}

#endif /* SUSFS_UID_FILTER_H */