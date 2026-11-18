# ASK2 offload on 802.3ad (LACP) bonds: contract, scope, and acceptance

**2026-11-18 · dpaa1 · Status: implemented on `feat/lacp` (kernel Inc 1+2, vyos-1x patch 061, rig battery); all local gates green; board acceptance pending (hardware).**

This document is written to be read by an independent reviewer with no prior
context. It states what the bond path *guarantees*, what it deliberately does
not do, and what has not yet been measured on real hardware. The full review
trail (seven rounds, findings F1..F-R7) is `doc/CHANGES-LACP.md`; the design
evidence base is `doc/FEASIBILITY-ASK-BOND.md` (../vyos-bonding/). Vendor ASK
1.x **declines** bonding offload — this work is beyond vendor parity, so no
vendor behaviour is binding here.

## 1. Executive summary

A routed flow whose ingress or egress netdev is an offloaded 802.3ad bond can
be carried by the FMan FE silicon. No new silicon mode exists: the bond is
resolved to physical member ports entirely inside `ask.ko` (S1 per §DUAL-
DATAPLANE). Everything about the bond is fail-closed — if any eligibility
predicate is not provably met, the flow stays in kernel software forwarding,
which is exactly the pre-feature behaviour.

Acceptance is gated on the board battery `bin/testrig-ask2-bond.sh` (§6); code
review and compile gates alone do NOT ship this feature.

## 2. Kernel contract (ask.ko)

1. **The bond stays the flow's L3 identity.** `f->oif`, the neighbour entry,
   the baked SMAC and conntrack's `iifidx` all reference the bond master,
   matching what software bonding emits. `ask.ko` never rewrites `oif` to a
   slave. (D1)
2. **Egress: one member per flow, deterministically.** The TX FQ is resolved
   on `ask_bond_hash_index(key, n)` — an XOR fold of the 5-tuple indexed from
   the HIGH word of a 64-bit golden-ratio product (sport reaches every slave
   count, incl. power-of-two; regression-guarded in kunit and
   `tests/hostcheck_bond.c`) over the ordered eligible-member set
   (enslaved, running, carrier, dpaa-backed; cap 8). No stored state: preflight,
   first insert, pending replay and neigh rebuild land on the same slave for
   the same key over the same set. Bitwise parity with `bond_xmit_hash()` is
   NOT required — determinism and spread are. (D2)
3. **Ingress: one FE record per engaged member.** Conntrack collapses the
   arrival slave into the bond, so the record cannot key on "the" ingress
   port; `ask_flow.hw[4]+n_hw` carries one record per eligible member (cap 4,
   extra members stay SW-only), each in its own per-port ehash table.
   Admission budget `ask_max_flows` charges per FE COPY, not per table entry
   (Q1, cumulative: publish charges `n_hw`, removal releases the same). (D4)
4. **Retirement doctrine: when in doubt, retire.** Any event touching the
   bond or a member — DOWN, UNREGISTER, CHANGEMTU, CHANGEADDR, CHANGE
   (carrier-only loss: the realistic cable-pull, emits ONLY NETDEV_CHANGE),
   or CHANGEUPPER-unlink — queues the bond's ifindex through the existing
   devchg flush; records retire, software re-forwards, the flowtable
   re-offloads and re-picks. SW coverage during the (sub-second) window means
   no packet loss, only a transiently slower path. (D3)
5. **Fail closed everywhere.** No eligible slave, no engaged member, budget
   exhausted, oversized slave set, or non-dpaa member ⇒ the flow never touches
   silicon. (D5)

## 3. CLI contract (vyos-1x patch 061)

- `set interfaces bonding bondX offload ipv4|ipv6` — engages every member
  FMan port with that family mask, adds bondX to `VYOS_FLOWTABLE_ASK_AUTO`
  (user flowtables still win), and `ethtool -K hw-tc-offload on` expands to
  the member ports (the bond master owns no NETIF_F_HW_TC).
- The offload leaves are **inherited bond options** (`BondIf.
  get_inherit_bond_options()`): each member's own `interfaces_ethernet` apply
  arms its port, so a member re-commit (description edit, address move) can
  never silently disengage the mask the bond relies on. The bond apply re-runs
  members on leaf or member-set changes via `call_dependents()`.
- Commit guards (verify): mode **802.3ad** only; bond MTU ∈ [1280, 9000]
  (FMan order-0 RX pool, mirrors patches 036/037); members must be FMan ports
  eth0–eth4; VPP mutual exclusion already rejected by the existing bonding
  verify (members in `vpp_ifaces`).

## 4. Scope limits and documented ceilings (deliberate)

| # | Ceiling | Posture / upgrade path |
|---|---|---|
| 1 | **LACP mux quiet window** — partner timeout with carrier kept emits no netdev event; HW-pinned flows could blackhole until bonding's own timers retire the slave | UNMEASURED — rig P6 measures it (Inc 3). Only if the gap is real: AD-state validation (Tier-B in-tree bonding export) or ship offload-on-bond as opt-in only |
| 2 | VLAN-over-bond / bond-over-VLAN | stays in software by construction (iif resolves to the VLAN dev, never a bond master → legacy fail-closed path). Q4: plain routed + NAT on bond is the shipped scope; encapsulations are fast-follow |
| 3 | Non-802.3ad bond modes | CLI-refused. The D2 hash is mode-agnostic; carrier-based eligibility is weaker without LACP. Round-robin/XOR/active-backup are policy follow-ons |
| 4 | > 4 eligible members get no ingress record (cap 4); > 8 refuse egress (cap 8) | boards carry ≤ 5 FMan ports; extra members SW-only, deterministic |
| 5 | Budget gate read vs publish-charge is not atomic (transient `ask_max_flows` overshoot ≤ racing replacers) | pre-existing shape, marked in `ask_flow.c`; reserve-at-gate upgrade path documented in code |
| 6 | Partial fan-out: if copy 0 defers (-EAGAIN) but copy 1 inserts, the entry publishes without the parked copy | that member SW-forwards until retirement; pending replay does not add copies to a live entry (F-R4/F4) |
| 7 | Multi-copy flows are excluded from the batched F-315 stats scan | per-flow direct read sums all copies instead; per-port scan slots are the marked upgrade |
| 8 | `lacp_rate`/`min_links` interactions unvalidated | documented, Q5; rig runs `lacp-rate fast` (P6's ~3 s timeout exercises the fast arm) |

## 5. Validation status

Run (sandbox, 2026-11-18, this tree):

- production `ask.ko` arm64 cross-build: clean, 0 warnings; production
  `__ksymtab` exports identical to `main` (the two new exports are
  `ASK_KUNIT_EXPORTS`-guarded);
- kunit variant compiles; only the documented `kunit_*` modpost failure
  (production kernel has CONFIG_KUNIT off — by design, BUILD.md §1);
- `tests/hostcheck_bond.c` passes (hash spread incl. the sport-only
  power-of-two regression + the withdraw worst-rc fold);
- vyos-1x chain 001..061 applies with zero rejects on upstream `5665f89e4`;
  every patched `.py` compiles; the offload XML node renders in the correct
  tree position;
- `bash -n` on the rig battery; P4/P6 capture points corrected in review
  rounds 7–8: bonding CONSUMES LACPDUs in its rx_handler (a bond0 tap is a
  guaranteed false FAIL — P4 captures members with `inbound`), and the kernel
  taps BEFORE the ingress qdisc runs (so a tc filter drop is invisible to
  tcpdump — P6 self-validates on the qdisc's own `dropped N` counter, not on
  tcpdump; round 8).

Pending (board gate — hardware expected week of 2026-11-23):

- [ ] kunit RUN on a CI `kunit=true` image (ask_bond 6 cases + copy-vector shape);
- [ ] `bin/testrig-ask2-bond.sh` P0–P8 on the 2-DUT + LACP-switch rig, incl.
      P5/P5b failover convergence, P6 quiet-window measurement (feeds the §4.1
      decision), P7 charged-vs-entry leak watch, P8 budget clamp;
- [ ] non-bond config regression: byte-identical offload behaviour (the no-op
      claim of D5);
- [ ] CI ISO build green with patch 061 (workflow_dispatch — human action).

## 6. Files

- `kernel/ask/oot-modules/ask/ask_bond.c` (+ hash in kunit/hostcheck mirrors)
- `ask_flow.c` (copy vector, budget), `ask_flow_offload.c` (fan-out plumbing,
  D3 flush arms), `ask_hw.c` (port-explicit preflight/insert, bond lowering)
- `data/vyos-1x-061-bonding-hw-offload.patch`
- `bin/testrig-ask2-bond.sh` — the acceptance battery
- Review trail: `doc/CHANGES-LACP.md` (rounds 1–7); evidence:
  `doc/FEASIBILITY-ASK-BOND.md`

## 7. Upstream-ability notes (vyos-1x)

Patch 061 is written to be upstreamable without the ASK internals: the
inherited-options mechanism, auto-flowtable expansion and the members
resolution for `ethtool -K` are generic shapes; the MTU bounds and eth0–eth4
validator are board-specific constants inside clearly-labelled LS1046A guard
blocks. The `get_hardware_offload_interfaces()` refactor is a strict
generalisation of the pre-existing per-device resolve (a member-less bond
resolves to none) and benefits any future bonded-offload upstreaming.
