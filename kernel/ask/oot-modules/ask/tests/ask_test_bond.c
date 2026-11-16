// SPDX-License-Identifier: GPL-2.0
/*
 * ASK2 - kunit suite for ask_bond.c (Inc 1, PLAN.md D2).
 *
 * ask_bond_hash_index() is the sole determinism guarantee behind per-flow
 * egress pinning: preflight, insert, pending replay and rebuild must all
 * pick the same slave for the same key over the same slave set, without
 * any stored state. It is a pure function, so it is fully testable here;
 * the netdev-walking half (ask_bond_select_egress) needs live bond
 * netdevs and lands in the rig suite (Inc 5) instead.
 */

#include <kunit/test.h>
#include <linux/in.h>
#include <linux/string.h>

#include "../include/ask_internal.h"

static void make_key_v4(struct ask_flow_key *k, __be32 sip, __be32 dip,
		       __be16 sport, __be16 dport)
{
	memset(k, 0, sizeof(*k));
	k->l3_proto = ASK_FLOW_L3_IPV4;
	k->l4_proto = IPPROTO_TCP;
	k->sport    = sport;
	k->dport    = dport;
	k->iif      = 1;
	memcpy(&k->src_ip[0], &sip, 4);
	memcpy(&k->dst_ip[0], &dip, 4);
}

static void make_key_v6(struct ask_flow_key *k, const u8 *sip, const u8 *dip,
		       __be16 sport, __be16 dport)
{
	memset(k, 0, sizeof(*k));
	k->l3_proto = ASK_FLOW_L3_IPV6;
	k->l4_proto = IPPROTO_TCP;
	k->sport    = sport;
	k->dport    = dport;
	k->iif      = 1;
	memcpy(k->src_ip, sip, 16);
	memcpy(k->dst_ip, dip, 16);
}

/* Distinct deterministic 4-tuples (v4), one per i. */
static void fill_key_seq_v4(struct ask_flow_key *k, unsigned int i)
{
	make_key_v4(k, htonl(0x0a000000 + i), htonl(0xc0a80000 + (i << 8)),
		    htons((u16)i), htons((u16)(i * 7 + 1)));
}

/*
 * Same key must always yield the same index -- evaluated twice; the real
 * cross-record guarantee follows because the function has no other input.
 */
static void ask_bond_test_hash_deterministic(struct kunit *test)
{
	struct ask_flow_key k;
	unsigned int i;

	for (i = 0; i < 64; i++) {
		u32 a, b;

		fill_key_seq_v4(&k, i);
		a = ask_bond_hash_index(&k, 4);
		b = ask_bond_hash_index(&k, 4);
		KUNIT_EXPECT_EQ(test, a, b);
	}
}

/* 0 slaves -> 0 (fail-closed contract); n>=1 -> result always < n. */
static void ask_bond_test_hash_bounds(struct kunit *test)
{
	struct ask_flow_key k;
	unsigned int i, n;

	fill_key_seq_v4(&k, 0);
	KUNIT_EXPECT_EQ(test, ask_bond_hash_index(&k, 0), 0u);

	for (n = 1; n <= 8; n++)
		for (i = 0; i < 128; i++) {
			u32 idx;

			fill_key_seq_v4(&k, i);
			idx = ask_bond_hash_index(&k, n);
			KUNIT_EXPECT_LT(test, idx, n);
			if (n == 1)
				KUNIT_EXPECT_EQ(test, idx, 0u);
		}
}

/* Shared spread check: 512 keys must visit every one of n buckets. */
static void expect_spread(struct kunit *test, unsigned int n, bool v6)
{
	unsigned long seen = 0;
	unsigned int i;

	for (i = 0; i < 512; i++) {
		struct ask_flow_key k;

		if (v6) {
			u8 sip[16] = { 0x20, 0x01, 0x0d, 0xb8 };
			u8 dip[16] = { 0x20, 0x01, 0x0d, 0xb9 };
			__be32 w = htonl(i);

			/* Only the high IPv6 word of dst varies: proves the
			 * v4-zeroed tail really participates for IPv6 keys. */
			memcpy(&dip[12], &w, 4);
			make_key_v6(&k, sip, dip, htons((u16)i),
				    htons((u16)(i * 7 + 1)));
		} else {
			fill_key_seq_v4(&k, i);
		}
		__set_bit(ask_bond_hash_index(&k, n), &seen);
	}
	KUNIT_EXPECT_EQ(test, seen, (1UL << n) - 1);
}

static void ask_bond_test_hash_spread_4(struct kunit *test)
{
	expect_spread(test, 4, false);
}

static void ask_bond_test_hash_spread_2(struct kunit *test)
{
	expect_spread(test, 2, false);
}

static void ask_bond_test_hash_spread_v6(struct kunit *test)
{
	expect_spread(test, 4, true);
}

static struct kunit_case ask_bond_test_cases[] = {
	KUNIT_CASE(ask_bond_test_hash_deterministic),
	KUNIT_CASE(ask_bond_test_hash_bounds),
	KUNIT_CASE(ask_bond_test_hash_spread_4),
	KUNIT_CASE(ask_bond_test_hash_spread_2),
	KUNIT_CASE(ask_bond_test_hash_spread_v6),
	{}
};

struct kunit_suite ask_bond_suite = {
	.name      = "ask_bond",
	.test_cases = ask_bond_test_cases,
};
