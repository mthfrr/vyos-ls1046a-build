#!/usr/bin/env bash
# testrig-ask2-bond.sh — ASK2 offload on an LACP (802.3ad) bond: validation battery
# (PLAN.md Inc 5; per-slave ingress records from Inc 2, CLI from vyos-1x patch 061,
# retirement measurements feeding Inc 3).
#
# Wiring: the LACP partner is a 10G switch.
#
#   DUT(bond0 = DUT_PORTS) ===two cables==== 10G switch (LACP port-channel)
#   GEN1(BOND_EP1_IF) --------one cable----> same switch, same VLAN
#   GEN2(BOND_EP2_IF) --------one cable----> same switch, same VLAN
#
# Transit flows run GEN1 <--> GEN2, FORCED through the DUT by /32 host routes, so
# every offloaded flow arrives with iif == bond0 and egresses bond0 - the exact
# Inc 1/2 egress-lowering + ingress-copy case.
#
# ONE-TIME SWITCH SETUP (operator; preflight below fails fast if it is wrong):
#   - port-channel containing the two DUT cables, LACP enabled (active or passive:
#     the DUT side is always active); member ports enslaved, no per-port blocking
#   - the channel + both generator ports in ONE flat VLAN carrying 10.98.0.0/24
#     and fd98::/64; the switch must NOT own a router/SVI for that VLAN
#   - set the channel's LACP timeout/rate to "fast" if configurable (speeds up P4;
#     at the 30 s default P4 waits longer but still passes)
#
# Nothing is saved on any box: VyOS changes are runtime commits (exit discard);
# the DUT is rebooted at the end to restore its saved config; generator changes are
# plain `ip` commands undone by the cleanup. NOREBOOT=1 skips the DUT reboot - then
# do it yourself before anything else touches the box.
#
# Usage: OUTDIR=... bin/testrig-ask2-bond.sh
# Env (besides testrig.env):
#   DUT_PORTS="eth3 eth4"         DUT bond members (FMan ports; raw-flushed at start)
#   BOND_EP1_IF=$GEN_IF           GEN1 data NIC cabled to the switch
#   BOND_EP2_IF=$GEN_IF           GEN2 data NIC cabled to the switch
#   DUR=10 REPS=1 FAILSECS=25 LEAK_REPS=20
#   NOREBOOT=1                    leave the DUT on the test config
#   CARRIER_OFF_CMD/CARRIER_ON_CMD  local commands that take $MEM1's LINK (carrier)
#                                 away / back WITHOUT admin-down on the DUT - e.g.
#                                 shut/no-shut the switch-side channel member. Set
#                                 BOTH to run P5b; unset skips it.
# Output: $OUTDIR/bond-*; one tagged line per check in bond-results.txt.
# REQUIRES an ISO with the feat/lacp kernel (ask.ko Inc 1+2) and vyos-1x patch 061.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/testrig-env.sh"
rig_require ASK2_DUT GEN1 GEN2
DUT_PORTS=${DUT_PORTS:-"eth3 eth4"}
BOND_EP1_IF=${BOND_EP1_IF:-$GEN_IF}
BOND_EP2_IF=${BOND_EP2_IF:-$GEN_IF}
DUR=${DUR:-10}; REPS=${REPS:-1}; FAILSECS=${FAILSECS:-25}; LEAK_REPS=${LEAK_REPS:-20}
RUN=${OUTDIR:?set OUTDIR to the run directory}; mkdir -p "$RUN"
# addressing: DUT router .1; EP1 .112; EP2 .113 (matches the rig's x.112/.113 habit)
D4=10.98.0.1; E14=10.98.0.112; E24=10.98.0.113
D6=fd98::1;   E16=fd98::112;   E26=fd98::113
SSHO=(-n -o BatchMode=yes -o ConnectTimeout=8 $RIG_SSHK)
d(){ ssh "${SSHO[@]}" "$ASK2_DUT" "$@"; }
di(){ ssh "${SSHO[@]}" "$ASK2_DUT" "$@"; }
e1(){ ssh "${SSHO[@]}" "$GEN1" "$@"; }
e2(){ ssh "${SSHO[@]}" "$GEN2" "$@"; }
# one VyOS configure session, runtime commit, never saved (testrig-ask2-wan.sh pattern)
vy_d(){ { echo 'source /opt/vyatta/etc/functions/script-template'; echo configure;
          printf '%s\n' "$@"; echo commit; echo 'exit discard'; } |
        di 'vbash -s' 2>&1 | grep -vE '^(\[edit\]|$)|discardChanges|Warning: configuration changes have not been saved' || true; }
# returns 0 when the session commits clean, 1 when the CLI reported an Error
vy_d_ok(){ vy_d "$@" | grep -qi 'Error:' && return 1 || return 0; }
MEM1=$(echo $DUT_PORTS | cut -d' ' -f1); MEM2=$(echo $DUT_PORTS | cut -d' ' -f2)
PASS=0; FAIL=0
res(){ local r=$1 ph=$2; shift 2
       printf '[%s] %s: %s\n' "$r" "$ph" "$*" | tee -a "$RUN/bond-results.txt"
       case $r in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; esac; }
abort(){ res ABORT "$1" "$2"; exit 1; }
flows(){ d "sudo /usr/local/bin/ynl --family ask --dump dump-flows --output-json" 2>/dev/null |
         python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo ERR; }
# Q1 accounting: get-info num-flows counts CHARGED FE copies (bond flows carry
# one per member); the table dump above counts entries and cannot see an
# orphaned FE record - a persistent charged-vs-entry drift is the record-leak
# signal (CHANGES-LACP.md review round 4 F-R4-1).
charged(){ d "sudo /usr/local/bin/ynl --family ask --do get-info --output-json" 2>/dev/null |
           python3 -c 'import json,sys;print(json.load(sys.stdin)["info"]["num-flows"])' 2>/dev/null || echo ERR; }
cpu(){ d "grep '^cpu ' /proc/stat"; }
busy(){ printf '%s\n%s\n' "$1" "$2" | awk '{for(i=2;i<=11;i++)a[NR,i]=$i} END{for(i=2;i<=11;i++){x=a[2,i]-a[1,i];T+=x;if(i==5||i==6)id+=x}; printf "%.1f",100*(T-id)/T}'; }
max_gap(){ python3 - "$1" "$2" <<'PY'
import re, sys
try:
    txt = open(sys.argv[1]).read()
except OSError:
    txt = ''
seqs = [int(m) for m in re.findall(r'icmp_seq=(\d+)', txt)]
g = max((b - a for a, b in zip(seqs, seqs[1:]) if b - a > 1), default=0)
print('%.1f' % (g / float(sys.argv[2])))
PY
}

cleanup(){
  e1 "sudo ip addr del $E14/24 dev $BOND_EP1_IF 2>/dev/null; sudo ip -6 addr del $E16/64 dev $BOND_EP1_IF 2>/dev/null
      sudo ip route del $E24/32 2>/dev/null; sudo ip -6 route del $E26/128 2>/dev/null; pkill -f 'iperf3' 2>/dev/null" >/dev/null 2>&1
  e2 "sudo ip addr del $E24/24 dev $BOND_EP2_IF 2>/dev/null; sudo ip -6 addr del $E26/64 dev $BOND_EP2_IF 2>/dev/null
      sudo ip route del $E14/32 2>/dev/null; sudo ip -6 route del $E16/128 2>/dev/null; pkill -f 'iperf3' 2>/dev/null" >/dev/null 2>&1
  [ "${NOREBOOT:-0}" = 1 ] && { echo "NOREBOOT: DUT stays on the test config - reboot before reuse"; return; }
  echo "rebooting the DUT to restore its saved config"
  d "sudo systemctl reboot" 2>/dev/null
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
vy_d "delete interfaces bonding bond9" >/dev/null

##### preflight — generator basics, then free the DUT members
e1 "which iperf3" >/dev/null || abort preflight 'iperf3 missing on GEN1'
e2 "which iperf3" >/dev/null || abort preflight 'iperf3 missing on GEN2'
for i in $DUT_PORTS; do d "sudo ip addr flush dev $i; sudo ip link set $i nomaster 2>/dev/null; true"; done

##### P1 — bond bring-up (DUT side) + forced-transit routing on the generators
vy_d "set interfaces bonding bond0 mode 802.3ad" "set interfaces bonding bond0 lacp-rate fast" \
     "set interfaces bonding bond0 offload ipv4" "set interfaces bonding bond0 offload ipv6" \
     $(for i in $DUT_PORTS; do echo "set interfaces bonding bond0 member interface $i"; done) \
     "set interfaces bonding bond0 address $D4/24" "set interfaces bonding bond0 address $D6/64"
e1 "sudo ip addr replace $E14/24 dev $BOND_EP1_IF; sudo ip -6 addr replace $E16/64 dev $BOND_EP1_IF nodad
    sudo ip route replace $E24/32 via $D4 dev $BOND_EP1_IF; sudo ip -6 route replace $E26/128 via $D6 dev $BOND_EP1_IF"
e2 "sudo ip addr replace $E24/24 dev $BOND_EP2_IF; sudo ip -6 addr replace $E26/64 dev $BOND_EP2_IF nodad
    sudo ip route replace $E14/32 via $D4 dev $BOND_EP2_IF; sudo ip -6 route replace $E16/128 via $D6 dev $BOND_EP2_IF"
sleep 15
d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-proc.txt"
if [ "$(grep -c 'MII Status: up' "$RUN/bond-dut-proc.txt")" -ge 3 ] && e1 "ping -c2 -W2 $E24 >/dev/null"; then
  res PASS P1 'LACP aggregated with the switch, transit GEN1->GEN2 via the DUT works'
else
  abort P1 'no LACP aggregation or no transit - recheck the switch checklist (port-channel LACP on, ONE flat VLAN for all three ports, no switch SVI on 10.98.0.0/24)'
fi
d "ping -c2 -W2 $E14 >/dev/null" && d "ping -6 -c2 -W2 $E26 >/dev/null" \
  && res PASS P1 'DUT reaches both generators (v4 + v6)' || res FAIL P1 'DUT cannot reach a generator (check addresses/VLAN)'

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
e2 "pkill -f 'iperf3 -s' 2>/dev/null; iperf3 -s -D -p 5281" >/dev/null 2>&1
iperf_run(){ # iperf_run <4|6> -> Gbit/s on stdout; GEN1 -> GEN2 through the DUT
  local src=$E14 dst=$E24
  [ "$1" = 6 ] && { src=$E16; dst=$E26; }
  e1 "timeout $((DUR + 30)) iperf3 -c $dst -B $src -p 5281 -P 4 -t $DUR -Z -J --bidir" > "$RUN/bond-iperf-v$1.json"
  python3 - "$RUN/bond-iperf-v$1.json" <<'PY'
import json, sys
try:
    j = json.load(open(sys.argv[1]))
    print('%.2f' % (j['end']['sum_received']['bits_per_second'] / 1e9))
except Exception:
    print(0)
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

##### P4 — LACPDU punt under engaged offload (timeout covers the switch's 30 s slow rate)
d "sudo timeout 40 tcpdump -qi bond0 -c1 'ether proto 0x8809' -nn" > "$RUN/bond-lacpdu.txt" 2>&1 \
  && res PASS P4 'LACPDUs visible on bond0 while offload engaged' \
  || res FAIL P4 'no LACPDUs on bond0 - punt regression (bond-lacpdu.txt)'

##### P5 — failover under load: pull one member, measure the transit gap (Inc 3 input)
e1 "ping -i 0.1 -c $((10 * (2 * FAILSECS))) $E24 > /tmp/bond-fail-ping.txt 2>&1 &
    iperf3 -c $E24 -B $E14 -p 5281 -t $((2 * FAILSECS)) -i 1 --bidir > /tmp/bond-fail-iperf.json 2>&1 &"
sleep 5
d "sudo ip link set $MEM1 down"
sleep $((FAILSECS - 5))
d "sudo ip link set $MEM1 up"
sleep $((FAILSECS + 10))
e1 "cat /tmp/bond-fail-ping.txt"  > "$RUN/bond-failover-ping.txt" 2>/dev/null
e1 "cat /tmp/bond-fail-iperf.json" > "$RUN/bond-failover-iperf.json" 2>/dev/null
e1 "pkill -f 'iperf3 -c' 2>/dev/null; pkill -f 'ping -i 0.1' 2>/dev/null" 2>/dev/null
d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-after-failover.txt"
res MEASURE P5 "pull-one-member transit gap $(max_gap "$RUN/bond-failover-ping.txt" 10)s (NETDEV_DOWN path: D3 flush must re-program; iperf json shows the retransmit collapse)"

##### P5b — carrier-only member loss (the NETDEV_CHANGE path; P5's admin-down does NOT cover it)
# Cable-pull / switch-side-port-shut leaves the DUT member administratively UP and
# emits only NETDEV_CHANGE - bonding never dev_close()s a slave over carrier loss.
# Needs link control outside the DUT, so it is opt-in; without it the carrier-loss
# flush arm goes untested (P6's tc-drop covers the quiet no-event case, not this).
if [ -n "${CARRIER_OFF_CMD:-}" ] && [ -n "${CARRIER_ON_CMD:-}" ]; then
  e1 "ping -i 0.1 -c $((10 * (2 * FAILSECS))) $E24 > /tmp/bond-carrier-ping.txt 2>&1 &
      iperf3 -c $E24 -B $E14 -p 5281 -t $((2 * FAILSECS)) -i 1 --bidir > /tmp/bond-carrier-iperf.json 2>&1 &"
  sleep 5
  eval "$CARRIER_OFF_CMD"
  sleep $((FAILSECS - 5))
  d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-during-carrier.txt"
  eval "$CARRIER_ON_CMD"
  sleep $((FAILSECS + 10))
  e1 "cat /tmp/bond-carrier-ping.txt"  > "$RUN/bond-carrier-ping.txt" 2>/dev/null
  e1 "cat /tmp/bond-carrier-iperf.json" > "$RUN/bond-carrier-iperf.json" 2>/dev/null
  e1 "pkill -f 'iperf3 -c' 2>/dev/null; pkill -f 'ping -i 0.1' 2>/dev/null" 2>/dev/null
  if grep -q icmp_seq "$RUN/bond-carrier-ping.txt" 2>/dev/null; then
    gap5b=$(max_gap "$RUN/bond-carrier-ping.txt" 10)
    awk "BEGIN{exit !($gap5b < 5)}" \
      && res PASS P5b "carrier-only loss transit gap ${gap5b}s (NETDEV_CHANGE flush works - seconds, not flowtable-timeout minutes)" \
      || res FAIL P5b "carrier-only loss transit gap ${gap5b}s - HW pinned to the dead member too long (NETDEV_CHANGE flush broken? see bond-dut-during-carrier.txt)"
  else
    res FAIL P5b 'no ping samples captured - test inconclusive'
  fi
else
  res SKIP P5b 'CARRIER_OFF_CMD/CARRIER_ON_CMD unset - carrier-only member loss (NETDEV_CHANGE flush) untested; P5 proves only the admin-down path'
fi

##### P6 — partner-timeout-with-carrier (the quiet case; measured, verdict is Inc 3's)
# Stop RECEIVING LACPDUs by dropping them at the DUT member's ingress qdisc - carrier
# stays up, no netdev event, and the DUT's bonding state machine must notice. This
# needs no switch access and IS the state under test (the mux expiry the D3 flush
# never sees). The pings run BEFORE the filter goes in: at lacp-rate fast the partner
# timeout is only ~3 s and must not elapse while we are still verifying.
e1 "ping -i 0.2 -c 175 $E24 > /tmp/bond-quiet-ping.txt 2>&1 &
    iperf3 -c $E24 -B $E14 -p 5281 -t 40 -i 1 --bidir > /tmp/bond-quiet-iperf.json 2>&1 &"
sleep 12   # let the iperf flows age past the offload delay so they ARE on silicon
d "sudo tc qdisc add dev $MEM1 ingress 2>/dev/null
   sudo tc filter add dev $MEM1 parent ffff: protocol all prio 1 u32 match u16 0x8809 0xffff at -2 action drop" >/dev/null 2>&1
sleep 3
# self-validation: tcpdump on the member (its tap sees ingress before the qdisc
# verdict) - if PDUs still arrive, the filter is broken; SKIP honestly
if d "sudo timeout 5 tcpdump -qi $MEM1 -c1 'ether proto 0x8809'" >/dev/null 2>&1; then
  res SKIP P6 'tc filter did not stop LACPDUs (syntax varies by iproute2) - repeat the drop your way, then measure'
else
  sleep 30
  d "cat /proc/net/bonding/bond0" > "$RUN/bond-dut-quiet.txt"
  e1 "pkill -f 'ping -i 0.2' 2>/dev/null; pkill -f 'iperf3 -c' 2>/dev/null
      cat /tmp/bond-quiet-ping.txt" > "$RUN/bond-quiet-transition-ping.txt" 2>/dev/null
  e1 "cat /tmp/bond-quiet-iperf.json" > "$RUN/bond-quiet-transition-iperf.json" 2>/dev/null
  expired=$(awk "/Slave Interface: $MEM1/,/^$/" "$RUN/bond-dut-quiet.txt" | grep -c 'Aggregator ID: 0\|MII Status: down')
  [ "${expired:-0}" -eq 0 ] && res MEASURE P6 'member NOT expired by the mux state machine after ~35 s without PDUs - itself a finding (check bond-dut-quiet.txt mux state)' \
    || res MEASURE P6 "member expired with carrier kept; transit gap during expiry $(max_gap "$RUN/bond-quiet-transition-ping.txt" 5)s (Inc 3 §4: was traffic silently HW-pinned to the stale slave?)"
fi
e1 "pkill -f 'ping -i 0.2' 2>/dev/null" 2>/dev/null
d "sudo tc qdisc del dev $MEM1 ingress 2>/dev/null"
sleep 30

##### P7 — member re-add cycles under churn, record-leak watch
e1 "iperf3 -c $E24 -B $E14 -p 5281 -t $((8 * LEAK_REPS)) -P 4 --bidir -i 5 > /dev/null 2>&1 &"
sleep 3
base=$(flows); base_c=$(charged)
for i in $(seq 1 "$LEAK_REPS"); do
  vy_d "delete interfaces bonding bond0 member interface $MEM2" >/dev/null; sleep 2
  vy_d "set interfaces bonding bond0 member interface $MEM2"   >/dev/null; sleep 2
done
sleep 15; after=$(flows); after_c=$(charged)
e1 "pkill -f 'iperf3 -c' 2>/dev/null" 2>/dev/null
d "sudo /usr/local/bin/ynl --family ask --dump dump-flows --output-json" > "$RUN/bond-flows-after-churn.json" 2>/dev/null
res MEASURE P7 "flow table: baseline=$base/$base_c after $LEAK_REPS member cycles=$after/$after_c entries/charged (compare again after settle; persistent growth - esp. of charged - = record leak; orphans are invisible to entries)"

##### P8 — budget clamp (D5: overflow must stay in software, never wedge)
before=$(d "cat /sys/module/ask/parameters/max_flows")
d "sudo sh -c 'echo 4 > /sys/module/ask/parameters/max_flows'"
e1 "for n in 1 2 3 4 5 6 7 8; do (iperf3 -c $E24 -B $E14 -p 5281 -t 6 -P 1 -w 256k >/dev/null 2>&1 &); sleep 1; done"
sleep 8
n_clamped=$(flows)
# The budget bounds CHARGED FE copies, not table entries: gate on num-flows
# (a 2-member bond doubles copies per entry - the sharpest available check
# that Q1 accounting holds under pressure). Margin 2x covers the documented
# transient gate overshoot (ask_flow.c insert-core budget comment).
c_clamped=$(charged)
d "sudo sh -c 'echo $before > /sys/module/ask/parameters/max_flows'"
ping_ok=$(e1 "ping -c2 -W2 $E24 >/dev/null" && echo yes || echo no)
[ "$n_clamped" != ERR ] && [ "$c_clamped" != ERR ] && [ "$c_clamped" -le 8 ] \
  && [ "$n_clamped" -le 12 ] && [ "$ping_ok" = yes ] \
  && res PASS P8 "budget clamp held (charged=$c_clamped vs cap 4, dumped=$n_clamped, ping fine) - no wedge" \
  || res FAIL P8 "budget clamp anomaly (charged=$c_clamped dumped=$n_clamped ping=$ping_ok)"

##### summary
res INFO ALL "PASS=$PASS FAIL=$FAIL - artefacts in $RUN; paste back bond-results.txt at minimum"
[ "$FAIL" -eq 0 ]
