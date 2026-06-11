# SuperEarn V2 — Security Review & Proof-of-Concept Suite

![tests](https://img.shields.io/badge/tests-10%20passing-brightgreen) ![fuzz](https://img.shields.io/badge/fuzz-2000%20runs-blue) ![solc](https://img.shields.io/badge/solc-0.8.29-informational) ![foundry](https://img.shields.io/badge/built%20with-Foundry-orange)

An independent security review of **SuperEarn V2** — a cross-chain yield-aggregation protocol (Kaia ⇄ Ethereum) built on asynchronous ERC-7540 request/fulfill/claim vaults and a dual-nonce bridge-accounting layer over Chainlink CCIP.

> 📄 **Full write-up:** [`SuperEarn-V2-Security-Review.md`](./SuperEarn-V2-Security-Review.md)

## TL;DR

A full manual review plus two **fuzzed, dynamic proofs-of-concept** against verbatim copies of the in-scope source. No exploitable in-scope vulnerability was found; the two highest-value hypotheses were **formally disproven** with conservation / no-inflation invariants holding across 4 000+ fuzz iterations. The negative results are documented as a first-class deliverable — they map the protocol's defenses and explain *why* they hold.

| Hypothesis | Domain | Verdict |
|---|---|---|
| **L-2** — bridge reconciliation / overlap inflates `OriginVault.totalAssets()` under reordered CCIP snapshots or nonce collision | Cross-chain accounting | **Disproven** (6/6, 2 000 fuzz) |
| **L-1** — withdrawal-queue `unfulfilledWithdrawalAmount` double-counts → fund loss / over-bridge | Vault exit accounting | **Disproven** (4/4, 2 000 fuzz) |

## Repository layout

```
SuperEarn-V2-Security-Review.md   ← the full security review (start here)
src/superearn/...                 ← 6 in-scope contracts, copied VERBATIM from the public release
test/BridgeAccountingPoC.t.sol    ← L-2 PoC: 6 tests (scenarios + fuzz + canary)
test/WithdrawalQueuePoC.t.sol     ← L-1 PoC: 4 tests (scenarios + fuzz)
foundry.toml                      ← production compiler config (solc 0.8.29, cancun, via_ir, runs=250)
```

The `src/` files are unmodified copies of the in-scope source so the accounting/control-flow under test is identical to the deployed bytecode. Heavy out-of-scope dependencies (Uniswap, Curve, Chainlink CCIP, Yearn, etc.) are not pulled in — each PoC isolates the exact surface it tests.

## Setup & run

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js.

```bash
# install dependencies (gitignored)
npm install
git clone --depth 1 --branch v1.9.7 https://github.com/foundry-rs/forge-std lib/forge-std

# run the full suite
forge test -vv

# deep fuzzing
FOUNDRY_FUZZ_RUNS=2000 forge test -vv
```

Expected:

```
Ran 2 test suites: 10 tests passed, 0 failed, 0 skipped (10 total tests)
```

## The two PoCs

### L-2 — Bridge reconciliation cannot inflate the Kaia side

Two real `BridgeAccountant` instances (Kaia origin + Ethereum remote) behind ERC-1967 proxies. The test plays both `CrosschainAdapter`s and delivers state snapshots with the same `timestamp >` gate as `_handle`. Invariant: `OriginPerceivedTotal ≤ TrueTotal` (no inflation) with exact convergence at rest.

| Test | Probes |
|---|---|
| `test_A_staleSnapshotNoDoubleCount` | C-01 class: bridge happens *after* the snapshot the origin holds |
| `test_B_reorderedConfirmationNoInflation` | remote confirms & drops a nonce before origin sees the newer snapshot |
| `test_C_bidirectionalInterleaved` | simultaneous bidirectional bridges, out-of-order delivery |
| `test_D_nonceCollisionNoCorruption` | forced outbound-nonce range collision (Kaia nonce == Ethereum nonce) |
| `testFuzz_E_noInflationUnderReordering` | 2 000 randomized adversarial orderings |
| `test_Z_canary_detectorWorks` | proves the inflation detector actually fires |

### L-1 — Withdrawal queue conserves funds

Logic-faithful model: the bodies of `handleWithdrawRequest` / `fulfillableAmount` / `fulfillPendingWithdrawals` (RemoteVault) and `processRedemptionQueue` / `batchFulfillRedemptions` / `redeem` (OriginVault) are copied verbatim (source line refs cited inline). Invariant: `originBalance + remoteUsdt + inTransit + paidOut == const`.

| Test | Probes |
|---|---|
| `test_S1_normalRoundTrip` | normal exit: user receives exactly what was requested |
| `test_S2_doubleSourceOverBridge` | double source (`processRedemptionQueue` + `withdrawFromRemote`) → `unfulfilled = 2×`; excess is **recoverable idle**, not lost |
| `test_S3_chunkedFulfillNoOverBridge` | chunked fulfillment never over-bridges |
| `testFuzz_S4_conservation` | 2 000 randomized interleavings — conservation never breaks |

## Scope of this work

This reviews the **public source release** of SuperEarn V2 for educational and portfolio purposes. It is not a guarantee of security and was not commissioned by the protocol team. All testing was local; no live system was touched.

## License

[MIT](./LICENSE) for the PoC/test code authored here. The copied `src/` contracts retain their original licenses (BUSL-1.1 / GPL-3.0) as marked in their SPDX headers and are included solely to make the proofs-of-concept reproducible.
