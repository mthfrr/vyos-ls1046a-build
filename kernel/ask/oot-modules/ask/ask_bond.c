// SPDX-License-Identifier: GPL-2.0
/*
 * ASK2 - bonding (802.3ad) egress slave selection (Inc 1, PLAN.md D1/D2/D5).
 *
 * A routed record keeps oif == the bond: the neighbour entry and the baked
 * SMAC are resolved on the bond and are exactly what SW bonding would emit
 * (D1). Only the TX FQ belongs to one physical slave, so bond flows need a
 * bond -> slave pick at fqid-resolution time.
 *
 * The pick is a pure function of the flow key (D2): no stored state, so
 * preflight, first insert, pending replay and rebuild-via-install all land
 * on the same slave for the same key over the same slave set. Any event
 * that can change that set flushes the bond's records (D3, see
 * ask_pppoe_netdev_event()), so a pin never outlives a topology change.
 *
 * Fail closed (D5): no eligible slave / oversized slave set -> 0 (no
 * egress), caller keeps the flow in software.
 */

#include <linux/hash.h>
#include <linux/netdevice.h>
#include <linux/rcupdate.h>
#include <linux/string.h>
#include <linux/types.h>

#include "ask_internal.h"

/*
 * Ceiling: ASK boards carry <= 5 physical FMan ports; a bond with more
 * eligible slaves than this fails closed (SW forward) rather than growing
 * the on-stack candidate set. Upgrade path: dynamically sized candidate
 * list (only ever needed if a bond can exceed 8 members here).
 */
#define ASK_BOND_MAX_SLAVES 8

/*
 * Pure hash: mirrors the *intent* of bonding's layer3+4 xmit policy
 * (bitwise parity with bond_xmit_hash() is NOT required; determinism and
 * spread are -- PLAN D2). XOR-fold the address words and the port pair,
 * avalanche with the golden-ratio multiply, mod the eligible-slave count.
 * IPv4 keys keep zero in src_ip/dst_ip[4..15], so the 4-word fold needs
 * no family branch (IPv6 folds all 16 bytes across the same four words).
 */
u32 ask_bond_hash_index(const struct ask_flow_key *key, unsigned int n)
{
	u32 hash = 0;
	unsigned int i;

	if (!n)
		return 0;

	for (i = 0; i < 4; i++) {
		__be32 sip, dip;

		memcpy(&sip, key->src_ip + 4 * i, sizeof(sip));
		memcpy(&dip, key->dst_ip + 4 * i, sizeof(dip));
		hash ^= (__force u32)sip ^ (__force u32)dip;
	}
	hash ^= ((u32)key->sport << 16) | (u32)key->dport;
	hash *= GOLDEN_RATIO_32;	/* xor-folds cluster; spread needs mix */

	return hash % n;
}
#ifdef ASK_KUNIT_EXPORTS
EXPORT_SYMBOL_GPL(ask_bond_hash_index);
#endif

struct ask_bond_slaves {
	unsigned int n;
	bool overflow;
	int ifindex[ASK_BOND_MAX_SLAVES];
};

static int ask_bond_eligible_lower(struct net_device *lower,
				   struct netdev_nested_priv *priv)
{
	struct ask_bond_slaves *s = priv->data;

	/*
	 * Eligible = enslaved to this bond (the walk is over this master's
	 * lowers, so master linkage is given) AND admin-up AND carrier on.
	 * The LACP mux state (AD_STATE_COLLECT) is not exported in-kernel;
	 * carrier is the available proxy -- Inc 3 measures whether the
	 * quiet mux-transition gap is real enough to need more.
	 */
	if (!netif_is_bond_slave(lower) || !netif_running(lower) ||
	    !netif_carrier_ok(lower))
		return 0;

	if (s->n == ASK_BOND_MAX_SLAVES) {
		s->overflow = true;
		return 1;		/* stop the walk; caller fails closed */
	}
	s->ifindex[s->n++] = lower->ifindex;
	return 0;
}

/* @bond's eligible egress slave ifindex for @key, or 0 (fail closed). */
int ask_bond_select_egress(const struct ask_flow_key *key,
			   struct net_device *bond)
{
	struct ask_bond_slaves s = {};
	struct netdev_nested_priv priv = { .data = &s };
	int rc;

	if (!key)
		return 0;

	rcu_read_lock();
	rc = netdev_walk_all_lower_dev_rcu(bond, ask_bond_eligible_lower,
					   &priv);
	rcu_read_unlock();

	if (rc || s.overflow || !s.n)
		return 0;

	return s.ifindex[ask_bond_hash_index(key, s.n)];
}
