#!/usr/bin/env bash
# test-vyos1x-061-chain.sh — offline smoke test for the vyos-1x patch series
# around the bonding HW-offload patch (Inc 4, review round 9).
#
# 1) every data/vyos-1x-0*.patch applies on the pinned dev clone (zero rejects),
# 2) the files patch 061 touches py_compile,
# 3) the bond-option inheritance copy really uses dict_set_nested() and the
#    multi-segment offload.ipv4/ipv6 leaves land in a member dict that has no
#    "offload" node (plain dict_set() raised KeyError there and failed every
#    commit that added members to an offloaded bond — the r9 bug).
#
# Needs the local vyos-1x dev clone (no network). Run: bin/test-vyos1x-061-chain.sh
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLONE="$REPO/vyos-build/scripts/package-build/vyos-1x/vyos-1x"
[ -d "$CLONE/src/conf_mode" ] || { echo "dev clone missing at $CLONE"; exit 1; }
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp -a "$CLONE/." "$SCRATCH/"
rm -rf "$SCRATCH/.git"

fails=0
for p in "$REPO"/data/vyos-1x-0*.patch; do
  patch -p1 -N -d "$SCRATCH" -i "$p" >/dev/null 2>&1 \
    || { echo "FAIL: apply $(basename "$p")"; fails=$((fails+1)); }
done
[ "$fails" = 0 ] && echo "OK: chain applies clean"

for f in src/conf_mode/interfaces_ethernet.py src/conf_mode/interfaces_bonding.py \
         src/conf_mode/firewall.py src/conf_mode/system_conntrack.py \
         python/vyos/ifconfig/bond.py; do
  python3 -m py_compile "$SCRATCH/$f" || { echo "FAIL: py_compile $f"; exit 1; }
done
echo "OK: py_compile clean"

grep -q "dict_set_nested(option_path, bond_option_value, eth_conf)" \
  "$SCRATCH/src/conf_mode/interfaces_ethernet.py" \
  || { echo "FAIL: loop-2 inheritance still uses dict_set (r9 KeyError regression)"; exit 1; }

cd "$SCRATCH/python" && python3 - <<'PY'
# Functional mirror of update_bond_options() loop 2 with the real helpers:
# bond owns "offload ipv4"; member carries no offload node at all.
import sys
sys.path.insert(0, '.')
from vyos.utils.dict import dict_set_nested, dict_search

eth_conf = {'ifname': 'eth3', 'mtu': '1500', 'is_bond_member': {'bond0': {}}}
bond = {'mode': '802.3ad', 'mtu': '1500', 'offload': {'ipv4': {}}}
for option_path in ('mtu', 'offload.ipv4', 'offload.ipv6'):  # get_inherit_bond_options()
    value = dict_search(option_path, bond)
    if value is not None:
        dict_set_nested(option_path, value, eth_conf)
mask = ((1 if dict_search('offload.ipv4', eth_conf) is not None else 0) |
        (2 if dict_search('offload.ipv6', eth_conf) is not None else 0))
assert mask == 1 and eth_conf['mtu'] == '1500', eth_conf
print('OK: offload leaf inherits into member (mask =', mask, ')')
PY
