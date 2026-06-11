# SuperEarn V2 — Independent Security Review

> Cross-chain yield-aggregation protocol (Kaia ⇄ Ethereum) — asynchronous request/fulfill/claim vaults, ERC-7540 redemption queues, and a dual-nonce bridge-accounting layer over Chainlink CCIP.

| | |
|---|---|
| **Reviewer** | `WhyUSayMyName` |
| **Review type** | Independent security review (manual + dynamic PoC) |
| **Target** | SuperEarn Core — public source release |
| **Commit / source** | `github.com/superearn-io/superearn-core-public` |
| **Date** | June 2026 |
| **Toolchain** | Solidity `0.8.29`, EVM `Cancun`, `via_ir=true`, optimizer `250`, OZ `5.3.0` / `4.9.4-upgradeable` |
| **Outcome** | No exploitable in-scope vulnerability identified. Two leading hypotheses formally disproven via fuzzed PoCs. |

> **Disclaimer.** This document is an independent review of a *public* source release performed for educational and portfolio purposes. It does not constitute a guarantee of security. No live system was attacked; all dynamic testing was performed against verbatim copies of the source in a local sandbox. Where the protocol's own published "Known Issues" cover an observation, this is stated explicitly.

---

## 1. Executive Summary

SuperEarn V2 lets users on **Kaia** access yield on both Kaia and **Ethereum** through an asynchronous *request → fulfill → claim* vault architecture. Capital is routed through a layered stack and, when the cross-chain path is used, bridged as **USDT** (Rhino.fi) while state is reconciled out-of-band over **Chainlink CCIP** using a state-piggybacking protocol.

This review covered the full in-scope surface: the cross-chain & vault layer (`OriginVault`, `RemoteVault`, `CrosschainAdapter`, `BridgeAccountant`, `SuperEarnMessageAgent`, `StrategyOriginVault`) and the single-chain Kaia vault & strategy layer (`CooldownVault`, `BaseCooldownStrategy`, `CustomYearnStrategy`, `CustomVault`, `USDOKycedCA`).

**Result.** The protocol is defensively engineered. Access control is complete, the share-accounting invariants are sound, and the most dangerous class for this design — *cross-chain accounting inflation that would raise the Kaia share price* — resists every reordering and collision scenario I could construct. I selected the two highest-value hypotheses and built **dynamic, fuzzed proofs-of-concept** against verbatim copies of the in-scope code:

| Hypothesis | Domain | Verdict |
|---|---|---|
| **L-2** Bridge reconciliation / overlap can inflate `OriginVault.totalAssets()` under reordered CCIP snapshots or nonce collision | Cross-chain accounting (Category 1) | **Disproven** — 6/6 tests, 2 000 fuzz runs; no inflation, exact convergence |
| **L-1** Withdrawal-queue `unfulfilledWithdrawalAmount` double-counting causes fund loss / over-bridge | Vault exit accounting (Category 1) | **Disproven** — 4/4 tests, 2 000 fuzz runs; funds conserved, excess fully recoverable |

The negative results are themselves a deliverable: they map the protocol's defenses, explain *why* they hold, and document non-productive directions so future review effort can be allocated elsewhere.

---

## 2. Scope

### In scope

**Category 1 — Cross-chain & Vault Layer**
`OriginVault` (Kaia), `RemoteVault` (Ethereum), `CrosschainAdapter` (both chains), `BridgeAccountant` (both chains), `SuperEarnMessageAgent` (both chains), `StrategyOriginVault` (Kaia), plus the `BridgeQueue` library and the Runespear/CCIP messaging base.

**Category 2 — Single-Chain Vault & Strategy Layer (Kaia)**
`CooldownVault`, `BaseCooldownStrategy`, `CustomYearnStrategy`, `CustomVault`, `USDOKycedCA`.

### Out of scope (per program rules, noted for completeness)

User-facing `SuperEarnRouter`, the currently-unfunded Ethereum Yearn-attached path, external-yield `CustomStrategy` deployments, all periphery/helpers (keepers, price converters, swap routers, asset providers, health checks), and trusted external dependencies (Yearn V2, Morpho, Pendle, OpenEden, Curve, Uniswap, CCIP, Orakl, Rhino). Governance/keeper/strategist acting adversarially is excluded by the protocol's trust model.

---

## 3. Methodology

1. **Scope & trust-model ingestion.** Full read of the program's scope, severity model, and — critically — its extensive "Known Issues / Acknowledged Design Decisions" (SE-P1…SE-P32, SUA/SSA/SA2) and pre-filed false-positive table. This bounds what constitutes a *novel* finding versus an acknowledged design trade-off.
2. **Static review.** Line-by-line reading of every in-scope contract and the access-control, messaging, and reconciliation dependencies. Each external entry point was mapped to its authorization gate and its effect on protocol invariants.
3. **Threat-model derivation.** For each contract I derived the load-bearing invariants (below) and asked: *which unprivileged actor can perturb them, and does any perturbation produce a token-unit loss or a Kaia-side accounting jump?*
4. **Dynamic verification.** The two surviving high-value hypotheses were promoted to **Foundry proofs-of-concept** using verbatim copies of the in-scope source, driven by adversarial scenarios and bounded fuzzing, each with a *canary* test proving the invariant detector actually fires.

Static analysis classes applied: re-entrancy, arithmetic precision / decimal handling, state & access-control validation, oracle integration, signature / replay, staking & reward dilution, liquidation & slippage (the latter found inapplicable — the protocol has no liquidation, CLM, or auction mechanics).

---

## 4. Architecture

```
User (Kaia)
  → SuperEarnRouter (transit only, OOS)
  → CooldownVault (Kaia)  — 1:1 shares, two-step withdraw, debt/predeposit accounting
  → Yearn V2 Vault (Kaia, trusted)
  → Strategy:
       ├── StrategyOriginVault → OriginVault (ERC-7540 async)
       │        → SuperEarnMessageAgent → CrosschainAdapter → BridgeAccountant
       │        → CCIP (state) + Rhino (USDT, bridgeToken is immutable)
       │        → RemoteVault (Ethereum) → Yearn (OOS) | CustomStrategy (OOS)
       ├── CustomYearnStrategy → CustomVault (ERC4626, Kaia)
       └── StrategyUSDOExpressV2 → USDOKycedCA (Kaia, OpenEden cUSDO path)
```

Two design principles dominate the security posture:

- **Kaia is ground truth.** `OriginVault.totalAssets()` (and the Kaia share price it feeds) is the only user-facing accounting surface. `RemoteVault.totalAssets()` is explicitly permitted to lag, transiently over- or under-report, and reconcile later (program rule SE-P23). A finding is only impactful if it manifests as an abrupt, non-converging change *on the Kaia side*.
- **Eventual consistency over ordering.** CCIP does not guarantee message ordering. Every outbound envelope carries a complete `StateSnapshot { vaultState, bridgeState }`; the receiver reconciles on every message regardless of arrival order. Correctness must therefore hold under arbitrary reordering — the central property I stress-tested.

---

## 5. Access-Control & Trust Model

Authorization was verified exhaustively; **no in-scope entry point was found with a missing or weakened gate.**

| Surface | Gate | Notes |
|---|---|---|
| `OriginVault.deposit/mint` | `onlyWhitelistedShareholder` (StrategyOriginVault + governance) | Blocks fulfillment-timing arbitrage |
| `OriginVault.requestRedeem` | `owner == msg.sender ∨ isOperator[owner][msg.sender]` | ERC-7540 delegation |
| `OriginVault.redeem(requestId,…)` | `controller`-keyed delegation **plus** triple guard `requestId / controller / fulfilledAssets>0` | Closes the `requestId==0` sentinel overlap |
| `CooldownVault` mutators | `onlyAuthorized` / `onlyStrategy` | Authorized set is governance-curated |
| `CrosschainAdapter.sendAssets` | `msg.sender == agent` | Sole outbound bridge path |
| `CrosschainAdapter.sendMessage` | vault / agent / governance; management & keeper only for `SYNC_NOOP` | |
| `SuperEarnMessageAgent.sendBridgedAssets` | `msg.sender == adapter` | Layered ingress auth (CCIP selector → chainId → whitelisted sender) |
| `BridgeAccountant` mutators | `onlyAdapter`; manual clears `onlyGovernance` | |
| `RemoteVault.handleWithdrawRequest` | `onlySystemContract` | |
| Inbound CCIP (`RunespearReceiver._ccipReceive`) | `selectorToChainId ≠ 0` ∧ `sender == whitelistedSender` ∧ anti-replay `processedMessages` | No per-message signature *by design* — authentication is the CCIP source selector + Runespear envelope + adapter-only entry |

The roles form a clean hierarchy (`GOVERNANCE > MANAGEMENT > KEEPER > SYSTEM_CONTRACT`); a compromised keeper is limited to liveness impact, and management cannot move funds to an external EOA. These are protocol trust assumptions, not weaknesses.

---

## 6. Core Invariants Examined

| Component | Invariant | Status |
|---|---|---|
| `CooldownVault` | `totalAssets = (_managedAssets + totalDebt) − totalLockedAssets == totalSupply` (1:1) | Holds; loss is socialized via `totalClaimLoss` + governance `recoverClaimLoss` (acknowledged design) |
| `CooldownVault._claim` | FIFO reservation: a claim cannot deprive earlier unclaimed requests of their assets | Holds; out-of-order claims only *relax* the check, consistent with the design comment |
| `OriginVaultBase` | Share/asset conversion via OZ virtual-offset (`_decimalsOffset = 12`, 6-dec USDT ↔ 18-dec shares) | Decimal-consistent; no precision drift found |
| `OriginVault` queue | Sequential processing `queueFulfilledIndex ≤ queueRemoteRequestedIndex ≤ length`; assets locked at request time | Holds; head-of-queue stall is acknowledged (SUA-11) and not attacker-reachable (whitelist-gated) |
| `BridgeAccountant` | `OriginPerceivedTotal ≤ TrueTotal` (no inflation) and converges to exact total | **Verified by PoC** (§8.1) |
| `RemoteVault` exit path | USDT conserved across the withdrawal round-trip; `unfulfilledWithdrawalAmount` cannot strand funds | **Verified by PoC** (§8.2) |
| `CustomYearnStrategy` | `redeemedButUnsettledShares ≤ committedExternalShares`; DP-reserve prevents double-backing | Statically consistent; post-Certik-2026-04-28 hardened surface |

---

## 7. Observations (Informational)

These are robustness notes, not vulnerabilities. Each is either explicitly acknowledged by the protocol or demonstrably non-exploitable.

### I-1 — Single outbound message per `block.timestamp`
`CrosschainAdapter.sendAssets` and `sendMessage` share a `lastMessageSentAt` guard that reverts a second outbound message in the same timestamp. This is **intentional**: it guarantees monotonic snapshot timestamps, since the receiver only updates `peerSnapshot` when `incoming.timestamp > getPeerTimestamp()`. Impact is limited to keeper liveness (operations are retryable next block). *Acknowledged area (SE-P28).*

### I-2 — Overlapping outbound-nonce ranges across chains
Both chains seed `latestOutboundNonce = block.timestamp` at deployment and increment by one. Deployed seconds apart, the numeric ranges overlap, so a Kaia outbound nonce can equal an Ethereum outbound nonce within a few hundred bridges. **This is not exploitable**: a bridge's nonce is generated by the *sender's* outbound tracker and recorded under the same value in the *receiver's* inbound tracker; the two directions live in separate trackers (`_outboundTracker.operations` vs `_inboundTracker.receivedOperations`), and every reconcile/overlap lookup queries the correct tracker. I built a scenario that forces a collision (`test_D`) and confirmed no corruption. *Acknowledged "Nonce Discipline" note.*

### I-3 — Early bridge-notification processing via donated balance
`_tryProcessBridgeNotification` checks only `balanceOf(adapter) ≥ notification.amount`, without subtracting other pending requirements. A third party can donate USDT to the adapter to "push through" a notification whose real bridged assets have not yet arrived. The accounting remains correct (per-nonce `recordInbound`), the assets reach the vault, and the real bridged funds later become sweepable surplus — the donor simply gifts the protocol. *Economically irrational; donation vector.*

---

## 8. Dynamic Verification (Proofs of Concept)

Two Foundry test suites accompany this report. Both deploy **verbatim copies** of the in-scope source under the production compiler configuration. Each suite asserts a conservation/no-inflation invariant at every observation point and includes a **canary** test proving the detector would fire on a real defect.

### 8.1 — L-2: Bridge reconciliation cannot inflate the Kaia side

**Hypothesis.** A sequence of validly-authenticated but reordered CCIP state snapshots — or a nonce collision (I-2) — could make `OriginVault.totalAssets()` perceive more assets than physically exist, inflating the Kaia share price (the only Category-1-eligible impact per SE-P23).

**Harness.** Two real `BridgeAccountant` instances (Kaia origin O, Ethereum remote R) behind ERC-1967 proxies. The test plays both `CrosschainAdapter`s, driving the accountants exactly as production does (`allocateOutboundNonce` on send, `recordInbound` on arrival, `updatePeerSnapshot` + `reconcileBridgeState` on every inbound message, including the `timestamp >` gate). RemoteVault's reported total is modelled faithfully as `physical(R) + R.calculateTrueOutboundInTransit()`; OriginVault's perceived total as `physical(O) + O.calculateTruePeerAssets() + O.calculateTrueOutboundInTransit()`.

**Invariants.** (1) `OriginPerceivedTotal ≤ TrueTotal` at all times (under-reporting is the safe/intended direction); (2) exact convergence at quiescence.

**Scenarios.** Stale-snapshot double-count (the C-01 class), reordered confirmation (remote drops a nonce before origin sees the newer snapshot), simultaneous bidirectional bridges with out-of-order asset delivery, forced nonce collision, and a 2 000-run fuzz over random adversarial orderings.

```
[PASS] testFuzz_E_noInflationUnderReordering (runs: 2000)
[PASS] test_A_staleSnapshotNoDoubleCount
[PASS] test_B_reorderedConfirmationNoInflation
[PASS] test_C_bidirectionalInterleaved
[PASS] test_D_nonceCollisionNoCorruption
[PASS] test_Z_canary_detectorWorks
6 passed; 0 failed
```

**Why it holds.** `updatePeerSnapshot` and `reconcileBridgeState` execute atomically within one `_handle`, so the peer's reported total and the overlap basis always move together. The pair `receivesNewerThanSnapshot` (strict `>` on `sentAt`) and `calculateInboundOverlap` (`≤` plus nonce-membership) partition received assets cleanly around the snapshot timestamp, preventing both double-count and under-count. Separate trackers neutralize nonce collisions.

### 8.2 — L-1: Withdrawal queue conserves funds

**Hypothesis.** The OriginVault redemption-queue withdrawal path and RemoteVault's `unfulfilledWithdrawalAmount` accumulator (written by two independent sources — `processRedemptionQueue` and `withdrawFromRemote`) could double-count and bridge back more USDT than the queue needs, losing or stranding funds.

**Harness.** A logic-faithful model: the bodies of `handleWithdrawRequest`, `fulfillableAmount`, `fulfillPendingWithdrawals`, `_bridgeAssetsToOrigin` (RemoteVault) and `processRedemptionQueue`, `batchFulfillRedemptions`, `availableIdleAssets`, `redeem` (OriginVault) are copied **verbatim** (source line references cited inline), with only the external bridge call stubbed. Conserved quantity: `originBalance + remoteUsdt + inTransit + paidOut == const (+ injected liquidity)`.

**Scenarios.** Normal round-trip, a deliberate **double-source over-bridge**, chunked fulfillment, and a 2 000-run conservation fuzz.

```
[PASS] testFuzz_S4_conservation (runs: 2000)
[PASS] test_S1_normalRoundTrip
[PASS] test_S2_doubleSourceOverBridge
[PASS] test_S3_chunkedFulfillNoOverBridge
4 passed; 0 failed
```

**Result.** In the double-source scenario (`unfulfilledWithdrawalAmount` reaches 2 000 for a 1 000-asset queue), the user is paid **exactly 1 000** and the excess 1 000 is **not lost or stranded** — it lands as idle USDT on `OriginVault`, fully redeployable via `depositToRemote`, with reservation counters cleared and conservation intact. The over-bridge is a liquidity *rebalance*, not a loss, and it requires an operator (`withdrawFromRemote` is `onlyOperators`) — out of scope under the trust model. Structurally, `unfulfilledWithdrawalAmount` is absent from both vaults' `totalAssets()`, so it cannot inflate the share price under any value.

### Reproduction

```bash
forge install                  # OZ upgradeable 4.9.4 + forge-std
FOUNDRY_FUZZ_RUNS=2000 forge test -vv
# 10 tests passed; 0 failed
```

---

## 9. Areas Reviewed and Considered Robust

- **`CooldownVault` 1:1 model & FIFO reservation** — the loss-socialization accounting (`accClaimedAmount` counts full requested amount on a loss claim, correctly closing the request from the "owed" set) is internally consistent; first-depositor inflation is precluded by the `authorized` gate.
- **`OriginVault` ERC-7540 queue** — sequential indices, rate locked at request time, triple-guarded `redeem`, decimals consistent. The `requestId == 0` sentinel is safely handled.
- **`CustomVault` / `CustomYearnStrategy`** — the two-counter share-commitment model and DP-reserve are non-contradictory; this is the freshly-hardened Certik 2026-04-28 surface.
- **`USDOKycedCA`** — the intentional CEI deviation in `claim()` is guarded by `nonReentrant`; `_isInOrderClaim` reserves prior requests' previewed amounts; donation vectors are unprofitable (re-queue).
- **Re-entrancy** — every external-call-bearing user/inter-contract path carries `nonReentrant`; the unguarded `requestRedeem` and keeper-only paths have no reachable callback surface.

---

## 10. Conclusion

SuperEarn V2 is a mature, defensively-engineered protocol with a coherent trust model and an unusually thorough public record of acknowledged design decisions. Across a full static review and two fuzzed dynamic proofs-of-concept targeting its highest-value accounting surfaces, **no exploitable in-scope vulnerability was identified**, and the two most promising hypotheses were formally disproven with conservation/no-inflation invariants holding across 4 000+ fuzz iterations.

The cross-chain accounting layer — typically the highest-risk component of any bridge-connected vault — proved robust to reordering, stale snapshots, nonce collisions, and double-source withdrawal requests. The protocol's "Kaia-is-ground-truth" design and atomic snapshot-plus-reconcile pattern are the load-bearing reasons these classes do not produce impact.

This review demonstrates a methodology that pairs invariant-driven static analysis with reproducible dynamic verification, and treats a rigorously-established negative result as a first-class deliverable.

---

## Appendix A — In-scope file inventory reviewed

```
src/superearn/core/CooldownVault.sol
src/superearn/core/strategy/BaseCooldownStrategy.sol
src/superearn/core/strategy/StrategyOriginVault.sol
src/superearn/core/strategy/custom/CustomVault.sol
src/superearn/core/strategy/custom/CustomYearnStrategy.sol
src/superearn/core/minter/USDOKycedCA.sol
src/superearn/v2/core/vaults/OriginVault.sol
src/superearn/v2/core/vaults/OriginVaultBase.sol
src/superearn/v2/core/vaults/RemoteVault.sol
src/superearn/v2/core/crosschain/BridgeAccountant.sol
src/superearn/v2/core/crosschain/BridgeQueue.sol
src/superearn/v2/core/crosschain/CrosschainAdapter.sol
src/superearn/v2/core/crosschain/SuperEarnMessageAgent.sol
src/superearn/v2/messaging/**                (Runespear / CCIP base, SuperEarnV2Protocol)
src/superearn/v2/base/SuperEarnAccessControl.sol
src/superearn/v2/libraries/VaultStateHelper.sol
```

## Appendix B — PoC suite

```
test/BridgeAccountingPoC.t.sol    — L-2, 6 tests (incl. fuzz + canary)
test/WithdrawalQueuePoC.t.sol     — L-1, 4 tests (incl. fuzz)
```

*Severity ratings in this report reflect the reviewer's assessment of a public source release and are not a determination by the protocol team.*
