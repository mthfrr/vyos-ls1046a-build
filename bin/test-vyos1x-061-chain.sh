#!/usr/bin/env bash
# test-vyos1x-061-chain.sh — offline smoke test for the vyos-1x patch series
# around the bonding HW-offload patch (Inc 4, review round 9).
#
# 1) every data/vyos-1x-0*.patch applies on the pinned dev clone (zero rejects),
# 2) the files patch 061 touches py_compile,
# 3) the bond-option inheritance copy really uses dict_set_nested() and the
#    multi-segment offload.ipv4/ipv6 leaves land in a member dict that has no
#    "offload" node (plain dict_set() raised KeyError there and failed every
#    commit that added members to an offloaded bond — the r9 bug),
# 4) interfaces_bonding.verify() executes: the ASK2 offload commit guards
#    (mode 802.3ad, MTU [1280,9000], members ⊂ eth0-eth4) really raise on the
#    bad configs and stay silent on the good one (Inc 4 guards had no
#    host-side execution coverage before; only the rig P0 covered them).
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

# 4) execute interfaces_bonding.verify() from the PATCHED tree: the ASK2
#    offload commit guards must fire on the bad configs and stay silent on
#    the good one. Host lacks the vyos runtime deps (netifaces, systemd,
#    vpp_papi) and the member loop probes live netdevs, so those are stubbed;
#    all guard LOGIC is the real patched code.
cd "$SCRATCH" && python3 - <<'PY'
import sys, types, importlib.util
sys.path.insert(0, 'python'); sys.path.insert(0, 'src/conf_mode')
def stub(name):
    m = types.ModuleType(name)
    m.__getattr__ = lambda k: (lambda *a, **kw: None)
    sys.modules[name] = m
for n in ('netifaces', 'systemd', 'systemd.journal', 'vpp_papi'):
    stub(n)
ni = sys.modules['netifaces']
ni.AF_INET, ni.AF_INET6, ni.AF_LINK = 2, 10, 17
sys.excepthook = sys.__excepthook__   # drop vyos.airbag's report hook
spec = importlib.util.spec_from_file_location(
    'ib', 'src/conf_mode/interfaces_bonding.py')
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)
from vyos import ConfigError
ib.interface_exists = lambda name: True            # member loop probes
class _Stub:
    def __init__(self, ifname): pass
    def check_bonding(self): return True
    def get_max_mtu(self): return 9000
    def get_min_mtu(self): return 68
ib.Ethtool = _Stub
ib.EthernetIf = _Stub

def bond(**kw):
    d = {'ifname': 'bond0', 'mode': '802.3ad', 'vpp_ifaces': {}}
    d.update(kw)
    return d
def mem(names):
    return {'member': {'interface': {n: {'new_added': {}} for n in names}}}

off = {'ipv4': {}}
# link-local guard disarmed via ipv6.address.no_default_link_local so the
# ASK MTU floor (not upstream's generic IPv6 floor) is what rejects 1200:
noll = {'ipv6': {'address': {'no_default_link_local': {}}}}
cases = [
    ('mode guard',       bond(offload=off, mode='round-robin'), 'mode 802.3ad'),
    ('MTU guard (high)', bond(offload=off, mtu='9500'),         'MTU between 1280 and 9000'),
    ('MTU guard (low)',  bond(offload=off, mtu='1200', **noll), 'MTU between 1280 and 9000'),
    ('FMan member gate', bond(offload=off, **mem(['eth7'])),    'eth0-eth4'),
]
for label, b, frag in cases:
    try:
        ib.verify(b)
    except ConfigError as e:
        assert frag in str(e), f'{label}: wrong message: {e}'
        print(f'OK: {label} rejects')
        continue
    raise SystemExit(f'FAIL: {label} did not raise')
ib.verify(bond(offload=off, **mem(['eth3', 'eth4'])))
print('OK: good offloaded bond (802.3ad, eth3+eth4) passes verify')
ib.verify(bond(mode='round-robin', **mem(['eth9'])))
print('OK: guards stay silent without the offload leaves')
PY
echo "OK: interfaces_bonding offload guards execute clean"
