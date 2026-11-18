// SPDX-License-Identifier: GPL-2.0
/*
 * Host-side self-check for the two PURE logic pieces of the bond offload
 * (PLAN.md D2 hash, Inc 2 withdraw fold). The kunit suite
 * (ask_test_bond.c, ask_test_flow.c) is authoritative but only RUNS on a
 * board/CI image; this mirror runs on any x86 host in milliseconds and
 * must fail if the mirrored logic below ever diverges from:
 *
 *   ask_bond_hash_index()        in ../ask_bond.c
 *   ask_flow_withdraw_owned()    worst-rc fold in ../ask_flow_offload.c
 *
 * Keep the two functions copied verbatim (types aside). Run:
 *   gcc -O2 -Wall -Werror hostcheck_bond.c -o /tmp/hostcheck && /tmp/hostcheck
 */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define GOLDEN_RATIO_32 0x9E3779B9

/* ask_flow_key, only the fields the hash consumes. */
struct key {
	uint8_t src_ip[16];
	uint8_t dst_ip[16];
	uint16_t sport, dport;
};

/* Verbatim mirror of ask_bond_hash_index(). */
static uint32_t bond_hash_index(const struct key *k, unsigned int n)
{
	uint32_t hash = 0;
	unsigned int i;

	if (!n)
		return 0;

	for (i = 0; i < 4; i++) {
		uint32_t sip, dip;

		memcpy(&sip, k->src_ip + 4 * i, sizeof(sip));
		memcpy(&dip, k->dst_ip + 4 * i, sizeof(dip));
		hash ^= sip ^ dip;
	}
	hash ^= ((uint32_t)k->sport << 16) | (uint32_t)k->dport;

	/* high word of the 64-bit golden-ratio product -- see ask_bond.c:
	 * mod n must read MIXED bits, not the raw low bits of the fold
	 * (sport lives in bits 16..31 and would never reach a mod 2/4 pick). */
	return (uint32_t)(((uint64_t)hash * GOLDEN_RATIO_32) >> 32) % n;
}

/* Verbatim mirror of the withdraw worst-rc fold (n_copies > 0 arm). */
static int withdraw_fold(const int *rrc, unsigned int n)
{
	unsigned int i;
	int worst = 0;

	for (i = 0; i < n; i++) {
		int r = rrc[i];

		if (r == -EAGAIN)
			worst = -EAGAIN;		/* quarantine wins */
		else if (r && r != -ESTALE && worst != -EAGAIN)
			worst = r;
		else if (r == -ESTALE && !worst)
			worst = -ESTALE;
	}
	return worst;
}

static void fill_seq(struct key *k, unsigned int i)
{
	/* Same memory image as the kunit key builders: addresses and ports
	 * stored in network order (htonl/htons on the host) -- the kernel
	 * only ever hashes wire-order keys. */
	uint32_t sip = __builtin_bswap32(0x0a000000u + i);
	uint32_t dip = __builtin_bswap32(0xc0a80000u + (i << 8));

	memset(k, 0, sizeof(*k));
	memcpy(k->src_ip, &sip, 4);	/* v4: bytes [4..15] stay zero */
	memcpy(k->dst_ip, &dip, 4);
	k->sport = (uint16_t)__builtin_bswap16((uint16_t)i);
	k->dport = (uint16_t)__builtin_bswap16((uint16_t)(i * 7 + 1));
}

int main(void)
{
	struct key k;
	unsigned int i, n;

	/* determinism (kunit: hash_deterministic) */
	for (i = 0; i < 64; i++) {
		fill_seq(&k, i);
		assert(bond_hash_index(&k, 4) == bond_hash_index(&k, 4));
	}

	/* bounds (kunit: hash_bounds) */
	fill_seq(&k, 0);
	assert(bond_hash_index(&k, 0) == 0);
	for (n = 1; n <= 8; n++)
		for (i = 0; i < 128; i++) {
			fill_seq(&k, i);
			assert(bond_hash_index(&k, n) < n);
		}

	/* spread over 4 and 2 buckets, v4 and v6-tail (kunit: hash_spread_*) */
	for (int pass = 0; pass < 3; pass++) {
		unsigned int buckets = pass == 1 ? 2 : 4;
		unsigned long seen = 0;

		for (i = 0; i < 512; i++) {
			fill_seq(&k, i);
			if (pass == 2) {	/* vary ONLY the high v6 word of dst */
				uint32_t w = __builtin_bswap32(i);	/* wire order */

				memcpy(k.dst_ip + 12, &w, 4);
			}
			seen |= 1UL << bond_hash_index(&k, buckets);
		}
		assert(seen == (1UL << buckets) - 1);
	}

	/* sport-only spread (kunit: hash_spread_sport): ONE host pair, fixed
	 * dport, 512 distinct sports must reach both members of a 2-slave
	 * bond. Regression guard for the pre-r5 hash, whose mod 2^m read
	 * only low fold bits and could never see sport at all. */
	{
		unsigned long seen = 0;
		uint32_t sip = __builtin_bswap32(0x0a000064u);
		uint32_t dip = __builtin_bswap32(0xc0a80001u);

		for (i = 1024; i < 1536; i++) {
			memset(&k, 0, sizeof(k));
			memcpy(k.src_ip, &sip, 4);
			memcpy(k.dst_ip, &dip, 4);
			k.sport = (uint16_t)__builtin_bswap16((uint16_t)i);
			k.dport = (uint16_t)__builtin_bswap16(5201);
			seen |= 1UL << bond_hash_index(&k, 2);
		}
		assert(seen == 0x3);
	}

	/* withdraw fold precedence: EAGAIN > hard > ESTALE > 0 */
	{
		const int ok[] = { 0, 0 };
		const int stale[] = { -ESTALE, -ESTALE };
		const int hard[] = { -ESTALE, -EIO };
		const int quarantine1[] = { -EAGAIN, -EIO };
		const int quarantine2[] = { -EIO, -EAGAIN };
		const int estale_then_again[] = { -ESTALE, -EAGAIN };

		assert(withdraw_fold(ok, 2) == 0);
		assert(withdraw_fold(stale, 2) == -ESTALE);
		assert(withdraw_fold(hard, 2) == -EIO);	/* hard beats ESTALE */
		assert(withdraw_fold(quarantine1, 2) == -EAGAIN);
		assert(withdraw_fold(quarantine2, 2) == -EAGAIN);
		assert(withdraw_fold(estale_then_again, 2) == -EAGAIN);
	}

	printf("hostcheck_bond: all assertions passed\n");
	return 0;
}
