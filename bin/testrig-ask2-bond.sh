#!/usr/bin/env bash
# testrig-ask2-bond.sh — ASK2 offload on an LACP (802.3ad) bond: validation battery
# (PLAN.md Inc 5; per-slave ingress records from Inc 2, CLI from vyos-1x patch 061,
# retirement measurements feeding Inc 3).
#
# Wiring assumed (everything env-parameterized; each assumption is asserted in
# preflight - the script ABORTs with a named reason rather than reporting a false FAIL):
#
#   OUT_HOST <saved-config network> DUT(OUT side) ... DUT(bond0 = DUT_PORTS)
#       DUT(bond0) <==== 802.3ad, two cables ====> PEER(bond0 = PEER_PORTS) --- LAN --> PEER side
#
#   PEER is a second VyOS box acting as the LACP partner and far traffic endpoint.
#   Transit flows run PEER <--> OUT_HOST through the DUT, so every offloaded flow
#   arrives with iif == bond0 on the DUT - the exact Inc 2 ingress-copy case.
#
# Nothing is saved on either box: all VyOS changes are runtime commits (exit discard).
# DUT and PEER are rebooted at the end to restore their saved configs; NOREBOOT=1
# skips the reboot - then do it yourself before anything else touches the boxes.
#
# Usage: OUTDIR=... bin/testrig-ask2-bond.sh
# Env (besides testrig.env):
#   PEER_DUT          VyOS LACP partner SSH target                            (required)
#   OUT_HOST          iperf3 server host, same L2 as the DUT's saved-config OUT side (required)
#   DUT_PORTS="eth3 eth4"     DUT bond members (FMan ports; raw-flushed at start)
#   PEER_PORTS="eth2 eth3"    PEER bond members, cabled DUT_PORTS[0]->PEER_PORTS[0], [1]->[1]
#   OUT_HOST_IF=eth0        OUT_HOST interface facing the DUT's OUT side
#   B4=10.98.0.1/24 B6=fd98::1/64   DUT bond0 addresses (PEER auto-picks .2)
#   DUR=10 REPS=1 FAILSECS=25 LEAK_REPS=20
#   NOREBOOT=1          leave both boxes on the test config
# Output: $OUTDIR/bond-*; one tagged line per check in bond-results.txt.
# REQUIRES an ISO with the feat/lacp kernel (ask.ko Inc 1+2) and vyos-1x patch 061.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/testrig-env.sh"
rig_require ASK2_DUT PEER_DUT OUT_HOST
DUT_PORTS=${DUT_PORTS:-"eth3 eth4"}
PEER_PORTS=${PEER_PORTS:-"eth2 eth3"}
OUT_HOST_IF=${OUT_HOST_IF:-eth0}
B4=${B4:-10.98.0.1/24}; B6=${B6:-fd98::1/64}
DUR=${DUR:-10}; REPS=${REPS:-1}; FAILSECS=${FAILSECS:-25}; LEAK_REPS=${LEAK_REPS:-20}
RUN=${OUTDIR:?set OUTDIR to the run directory}; mkdir -p "$RUN"
SSHO=(-n -o BatchMode=yes -o ConnectTimeout=8 $RIG_SSHK)
d(){ ssh "${SSHO[@]}" "$ASK2_DUT" "$@"; }
di(){ ssh "${SSHO[@]}" "$ASK2_DUT" "$@"; }
p(){ ssh "${SSHO[@]}" "$PEER_DUT" "$@"; }
o(){ ssh "${SSHO[@]}" "$OUT_HOST" "$@"; }
# one VyOS configure session, runtime commit, never saved (testrig-ask2-wan.sh pattern)
vy_raw(){ local tgt=$1; shift
  { echo 'source /opt/vyatta/etc/functions/script-template'; echo configure; printf '%s\n' "$@"; echo commit; echo 'exit discard'; } |
    "$tgt" 'vbash -s' 2>&1 | grep -vE '^(\[edit\]|$)|discardChanges|Warning: configuration changes have not been saved' || true; }
vy_d(){ vy_raw di "$@"; }
vy_p(){ vy_raw p "$@"; }
# returns 0 when the session commits clean, 1 when the CLI reported an Error
vy_d_ok(){ vy_d "$@" | grep -qi 'Error:' && return 1 || return 0; }
MEM1=$(echo $DUT_PORTS | cut -d' ' -f1); MEM2=$(echo $DUT_PORTS | cut -d' ' -f2)
BOND_IP=${B4%/*}; PEER_BOND_IP=${B4%.*}.2
B6_IP=${B6%/*}; PEER_B6=$(echo "$B6" | sed 's/:1\/64/:2\/64/'); PEER_B6_IP=${PEER_B6%/*}
B4_NET=${B4%.*}.0/24
PASS=0; FAIL=0
res(){ local r=$1 ph=$2; shift 2
       printf '[%s] %s: %s\n' "$r" "$ph" "$*" | tee -a "$RUN/bond-results.txt"
       case $r in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; esac; }
abort(){ res ABORT "$1" "$2"; exit 1; }
flows(){ d "sudo /usr/local/bin/ynl --family ask --dump dump-flows --output-json" 2>/dev/null |
         python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo ERR; }
cpu(){ d "grep '^cpu ' /proc/stat"; }
busy(){ printf '%s\n%s\n' "$1" "$2" | awk '{for(i=2;i<=11;i++)a[NR,i]=$i} END{for(i=2;i<=11;i++){x=a[2,i]-a[1,i];T+=x;if(i==5||i==6)id+=x}; printf "%.1f",100*(T-id)/T}'; }

cleanup(){
  [ "${NOREBOOT:-0}" = 1 ] && { echo "NOREBOOT: both boxes stay on the test config - reboot before reuse"; return; }
  echo "rebooting DUT and PEER to restore saved configs"
  p "sudo systemctl reboot" 2>/dev/null; d "sudo systemctl reboot" 2>/dev/null
}
trap cleanup EXIT

##### P0 — CLI guards (wiring-free; runs first so partial value survives missing wiring)
d "test -e /sys/module/ask/parameters/max_flows" || abort P0 'ask.ko without max_flows (old ISO, pre-Inc-1?)'
d "test -x /usr/local/bin/ynl" || abort P0 'ynl client missing (old ISO?)'
# positive control first: the good commit must pass, or a later "rejection" means nothing
if vy_d_ok "set interfaces bonding bond9 offload ipv4"; then
  res PASS P0 'offload leaf accepted on bonding (patch 061 rendered)'
else
  abort P0 'bonding offload leaf not accepted - vyos-1x patch 061 missing from the ISO?'
fi
vy_d_ok "set interfaces bonding bond9 mode round-robin" \
  && res FAIL P0 'mode round-robin + offload committed (guard missing)' \
  || res PASS P0 'mode != 802.3ad + offload rejected'
vy_d_ok "set interfaces bonding bond9 mtu 9500" \
  && res FAIL P0 'MTU 9500 + offload committed (guard missing)' \
  || res PASS P0 'MTU outside [1280,9000] + offload rejected'
d "vbash -c 'configure; delete interfaces bonding bond9; commit; exit discard'" >/dev/null 2>&1

##### preflight — wiring and tooling
OUT_IP=$(d "ip route show default | awk '{print \$5; exit}'")
[ -n "$OUT_IP" ] || abort preflight 'DUT has no default route in its running config - the OUT-side assumption fails'
o "ping -c2 -W2 $OUT_IP" >/dev/null 2>&1 || abort preflight "OUT_HOST cannot reach the DUT OUT address $OUT_IP (check OUT_HOST/$OUT_HOST_IF)"
o "which iperf3" >/dev/null || abort preflight 'iperf3 missing on OUT_HOST'
p "which iperf3" >/dev/null || abort preflight 'iperf3 missing on PEER'
for i in $DUT_PORTS; do d "sudo ip addr flush dev $i; sudo ip link set $i nomaster 2>/dev/null; true"; done

##### P1 — bond bring-up both sides, LACP active
vy_d "set interfaces bonding bond0 mode 802.3ad" "set interfaces bonding bond0 lacp-rate fast" \
     "set interfaces bonding bond0 offload ipv4" "set interfaces bonding bond0 offload ipv6" \
     $(for i in $DUT_PORTS; do echo "set interfaces bonding bond0 member interface $i"; done) \
     "set interfaces bonding bond0 address $B4" "set interfaces bonding bond0 address $B6"
vy_p "set interfaces bonding bond0 mode 802.3ad" "set interfaces bonding bond0 lacp-rate fast" \
     $(for i in $PEER_PORTS; do echo "set interfaces bonding bond0 member interface $i"; done) \
     "set interfaces bonding bond0 address ${PEER_BOND_IP}/24" "set interfaces bonding bond0 address ${PEER_B6}/64" \
     "set protocols static route $B4_NET next-hop $BOND_IP"
sleep 15
d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-proc.txt"
p "cat /proc/net/bonding/bond0" > "$RUN/bond-peer-proc.txt"
if d "ping -c2 -W2 $PEER_BOND_IP >/dev/null" && p "ping -c2 -W2 $BOND_IP >/dev/null"; then
  [ "$(grep -c 'MII Status: up' "$RUN/bond-dut-proc.txt")" -ge 3 ] \
    && res PASS P1 'LACP active, bond reachable both directions' \
    || res FAIL P1 'ping OK but bond MII not fully up (see bond-dut-proc.txt)'
else
  abort P1 'bond0 not reachable - check DUT_PORTS<->PEER_PORTS cabling order (swapping PEER_PORTS is the usual fix)'
fi
p "ping -c2 -W2 $OUT_HOST >/dev/null" || abort preflight 'PEER cannot reach OUT_HOST via the new route (check the OUT subnet assumption)'
o "sudo ip route replace $B4_NET via $OUT_IP dev $OUT_HOST_IF"

##### P2 — patch 061 rendering: auto flowtable on bond0, hw-tc-offload on members
d "nft list table ip vyos_filter"  > "$RUN/bond-nft-v4.txt"
d "nft list table ip6 vyos_filter" > "$RUN/bond-nft-v6.txt"
grep -A2 'flowtable VYOS_FLOWTABLE_ASK_AUTO' "$RUN/bond-nft-v4.txt" | grep -q bond0 \
  && res PASS P2 'auto flowtable device includes bond0 (v4)' || res FAIL P2 'bond0 missing from VYOS_FLOWTABLE_ASK_AUTO (v4)'
grep -A2 'flowtable VYOS_FLOWTABLE_ASK_AUTO' "$RUN/bond-nft-v6.txt" | grep -q bond0 \
  && res PASS P2 'auto flowtable device includes bond0 (v6)' || res FAIL P2 'bond0 missing from VYOS_FLOWTABLE_ASK_AUTO (v6)'
for i in $DUT_PORTS; do
  d "ethtool -k $i" | grep -q 'hw-tc-offload: on' && res PASS P2 "hw-tc-offload on on $i" \
    || res FAIL P2 "hw-tc-offload off on $i (expansion to members broken?)"
done

##### P3 — steady-state offload: flows present, DUT CPUs idle
o "pkill -f 'iperf3 -s' 2>/dev/null; iperf3 -s -D -p 5281" >/dev/null 2>&1
iperf_run(){ # iperf_run <4|6> -> Gbit/s on stdout
  local src=$PEER_BOND_IP dst=$BOND_IP
  [ "$1" = 6 ] && { src=$PEER_B6_IP; dst=$B6_IP; }
  p "timeout $((DUR + 30)) iperf3 -c $OUT_HOST -B $src -p 5281 -P 4 -t $DUR -Z -J" > "$RUN/bond-iperf-v$1.json"
  python3 - "$RUN/bond-iperf-v$1.json" <<'PY'
import json, sys
try: j = json.load(open(sys.argv[1])); print('%.2f' % (j['end']['sum_received']['bits_per_second'] / 1e9))
except Exception: print(0)
PY
}
for rep in $(seq 1 "$REPS"); do for fam in 4 6; do
  c0=$(cpu); gb=$(iperf_run "$fam" | tail -1); c1=$(cpu); b=$(busy "$c0" "$c1")
  sleep 2
  flows > "$RUN/bond-flowcount-v$fam-r$rep.txt"
  d "sudo /usr/local/bin/ynl --family ask --dump dump-flows --output-json" > "$RUN/bond-flows-v$fam-r$rep.json" 2>/dev/null
  nf=$(cat "$RUN/bond-flowcount-v$fam-r$rep.txt")
  printf '[INFO] P3 r%s v%s: %s Gbit/s, DUT busy %s%%, ask flows %s\n' "$rep" "$fam" "$gb" "$b" "$nf" | tee -a "$RUN/bond-results.txt"
  [ "$rep" = "$REPS" ] && { [ "$nf" != ERR ] && [ "$nf" -gt 0 ] && awk "BEGIN{exit !($b < 15)}" \
    && res PASS P3 "v$fam offloaded (flows=$nf, busy ${b}%)" \
    || res FAIL P3 "v$fam not visibly offloaded (flows=$nf busy=${b}% gbps=$gb)"; }
done; done

##### P4 — LACPDU punt under engaged offload (lacp-rate fast => ~1s between PDUs)
d "sudo timeout 10 tcpdump -qi bond0 -c2 'ether proto 0x8809' -nn" > "$RUN/bond-lacpdu.txt" 2>&1 \
  && res PASS P4 'LACPDUs visible on bond0 while offload engaged' \
  || res FAIL P4 'no LACPDUs on bond0 - punt regression (bond-lacpdu.txt)'

##### P5 — failover under load: pull one member, measure the transit gap (Inc 3 input)
p "iperf3 -c $OUT_HOST -B $PEER_BOND_IP -p 5281 -t $((2 * FAILSECS)) -i 1 > /tmp/bond-fail-iperf.json 2>&1 &
   ping -i 0.1 -c $((10 * (2 * FAILSECS))) $OUT_HOST > /tmp/bond-fail-ping.txt 2>&1 &"
sleep 5
d "sudo ip link set $MEM1 down"
sleep $((FAILSECS - 5))
d "sudo ip link set $MEM1 up"
sleep $((FAILSECS + 10))
p "cat /tmp/bond-fail-ping.txt"  > "$RUN/bond-failover-ping.txt" 2>/dev/null
p "cat /tmp/bond-fail-iperf.json" > "$RUN/bond-failover-iperf.json" 2>/dev/null
p "pkill -f 'iperf3 -c' 2>/dev/null" 2>/dev/null
d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-after-failover.txt"
python3 - "$RUN/bond-failover-ping.txt" "$RUN/bond-failover-gap.txt" <<'PY'
import re, sys
seqs = [int(m) for m in re.findall(r'icmp_seq=(\d+)', open(sys.argv[1]).read())] if open(sys.argv[1]).read() else []
g = max((b - a for a, b in zip(seqs, seqs[1:]) if b - a > 1), default=0)
gap = g / 10.0
open(sys.argv[2], 'w').write('%.1f\n' % gap)
print('%.1f' % gap)
PY
res MEASURE P5 "pull-one-member transit gap $(cat "$RUN/bond-failover-gap.txt" 2>/dev/null || echo '?')s (iperf intervals show retransmit collapse; feed into the Inc 3 matrix)"

##### P6 — partner-timeout-with-carrier (the quiet case; measured, verdict is Inc 3's)
PEER_MEM=$(awk '/Slave Interface/{print $3; exit}' "$RUN/bond-peer-proc.txt")
# drop ONLY LACPDUs (ethertype at -2 = last 2 bytes before the L3 header)
p "sudo tc qdisc add dev $PEER_MEM ingress 2>/dev/null
   sudo tc filter add dev $PEER_MEM parent ffff: protocol all prio 1 u32 match u16 0x8809 0xffff at -2 action drop" >/dev/null 2>&1
sleep 1
if d "timeout 6 tcpdump -qi $MEM1 -c1 'ether proto 0x8809'" >/dev/null 2>&1; then
  res SKIP P6 'tc filter did not stop LACPDUs (syntax varies by iproute2) - repeat the drop your way, then measure'
else
  p "ping -i 0.2 -c 150 $OUT_HOST > /tmp/bond-quiet-ping.txt 2>&1" || true
  p "cat /tmp/bond-quiet-ping.txt" > "$RUN/bond-quiet-transition-ping.txt" 2>/dev/null
  d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-quiet.txt"
  res MEASURE P6 'LACPDUs stopped, carrier kept: blackhole window from bond-quiet-transition-ping.txt (Inc 3 §4 - was traffic silently HW-pinned to the stale slave?)'
fi
p "sudo tc qdisc del dev $PEER_MEM ingress 2>/dev/null"
sleep 30

##### P7 — member re-add cycles under churn, record-leak watch
p "iperf3 -c $OUT_HOST -B $PEER_BOND_IP -p 5281 -t $((8 * LEAK_REPS)) -P 4 -i 5 > /dev/null 2>&1 &"
sleep 3
base=$(flows)
for i in $(seq 1 "$LEAK_REPS"); do
  vy_d "delete interfaces bonding bond0 member interface $MEM2" >/dev/null; sleep 2
  vy_d "set interfaces bonding bond0 member interface $MEM2"   >/dev/null; sleep 2
done
sleep 15; after=$(flows)
p "pkill -f 'iperf3 -c' 2>/dev/null" 2>/dev/null
d "sudo /usr/local/bin/ynl --family ask --dump dump-flows --output-json" > "$RUN/bond-flows-after-churn.json" 2>/dev/null
res MEASURE P7 "flow table: baseline=$base after $LEAK_REPS member cycles=$after (compare again after settle; persistent growth = record leak)"

##### P8 — budget clamp (D5: overflow must stay in software, never wedge)
before=$(d "cat /sys/module/ask/parameters/max_flows")
d "sudo sh -c 'echo 4 > /sys/module/ask/parameters/max_flows'"
p "for n in 1 2 3 4 5 6 7 8; do (iperf3 -c $OUT_HOST -B $PEER_BOND_IP -p 5281 -t 6 -P 1 -w 256k >/dev/null 2>&1 &); sleep 1; done"
sleep 8
n_clamped=$(flows)
d "sudo sh -c 'echo $before > /sys/module/ask/parameters/max_flows'"
ping_ok=$(d "ping -c2 -W2 $PEER_BOND_IP >/dev/null" && echo yes || echo no)
[ "$n_clamped" != ERR ] && [ "$n_clamped" -le 12 ] && [ "$ping_ok" = yes ] \
  && res PASS P8 "budget clamp held (dumped=$n_clamped vs cap 4, ping fine) - no wedge" \
  || res FAIL P8 "budget clamp anomaly (dumped=$n_clamped ping=$ping_ok)"

##### summary
res INFO ALL "PASS=$PASS FAIL=$FAIL - artefacts in $RUN; paste back bond-results.txt at minimum"
[ "$FAIL" -eq 0 ]
