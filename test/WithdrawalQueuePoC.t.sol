// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Test } from "forge-std/Test.sol";

/**
 * @title WithdrawalQueuePoC
 * @notice Probes lead L-1: can the OriginVault redemption-queue withdrawal path and the
 *         RemoteVault `unfulfilledWithdrawalAmount` accumulator double-count, causing the
 *         system to bridge back to Kaia MORE USDT than the queue needs, or to lose/strand
 *         USDT across the round-trip?
 *
 * Faithfulness: this is a LOGIC-faithful harness. The function bodies of the in-scope
 * functions are copied VERBATIM from the source (line refs cited inline), with only the
 * external bridge call and balance reads stubbed. It is NOT bytecode-faithful (a full-contract
 * fork PoC is "variant 2"). The arithmetic / control-flow being tested is identical to source.
 *
 * Conserved quantity (no USDT may be created or destroyed):
 *   SYSTEM = originBalance + remoteUsdt + inTransitRtoO + paidOutToUsers   == constant
 *            (modulo externally injected liquidity, tracked explicitly).
 */
contract WithdrawalQueuePoC is Test {
    // ===== RemoteVault (Ethereum) state =====
    uint256 internal remoteUsdt; // RemoteVault USDT balance
    uint256 internal unfulfilledWithdrawalAmount; // RemoteVault.sol:93

    // ===== OriginVault (Kaia) state =====
    uint256 internal originBalance; // USDT held by OriginVault
    uint256 internal totalReservedRedemptionAssets; // OriginVault.sol:165
    uint256 internal totalFulfilledRedemptionAssets; // OriginVault.sol:172
    uint256 internal queueRemoteRequestedIndex; // OriginVault.sol:180
    uint256 internal queueFulfilledIndex; // OriginVault.sol:181

    struct QItem {
        uint256 shares;
        uint256 requestedAssets;
        uint256 fulfilledAssets;
        bool redeemed;
    }

    QItem[] internal redemptionQueue;

    // ===== bridge pipe R -> O (fulfillment leg) =====
    struct Leg {
        uint256 amount;
        bool delivered;
    }

    Leg[] internal legs;

    // ===== conservation bookkeeping =====
    uint256 internal paidOutToUsers;
    uint256 internal injectedLiquidity; // external liquidity added to remote (e.g. yearn withdraw / donation)

    // ===================================================================================
    // OriginVault: availableIdleAssets() — OriginVault.sol:317-322
    // ===================================================================================
    function _availableIdleAssets() internal view returns (uint256) {
        uint256 balance = originBalance;
        uint256 reserved = totalReservedRedemptionAssets + totalFulfilledRedemptionAssets; // reservedAssets()
        uint256 localReserved = reserved > balance ? balance : reserved;
        return balance > localReserved ? balance - localReserved : 0;
    }

    // ===================================================================================
    // OriginVault: requestRedeem (simplified enqueue) — OriginVault.sol:601-644
    // requestedAssets locked at request time (here 1:1 shares==assets for USDT)
    // ===================================================================================
    function _requestRedeem(uint256 assets) internal {
        redemptionQueue.push(QItem({ shares: assets, requestedAssets: assets, fulfilledAssets: 0, redeemed: false }));
    }

    // ===================================================================================
    // OriginVault: processRedemptionQueue — OriginVault.sol:491-541 (verbatim logic)
    // Returns amountToRequestFromRemote (and "sends" a WITHDRAW to remote for that shortfall).
    // ===================================================================================
    function _processRedemptionQueue(uint256 maxAmountUsdt, uint256 maxCount) internal returns (uint256) {
        require(maxAmountUsdt != 0, "ZeroMaxAmount");

        uint256 totalShares = 0;
        uint256 totalRequestedAssets = 0;
        uint256 startIndex = queueRemoteRequestedIndex;
        uint256 endIndex = redemptionQueue.length;
        endIndex = endIndex - startIndex < maxCount ? endIndex : startIndex + maxCount;

        uint256 initialAvailableIdle = _availableIdleAssets();

        for (uint256 i = startIndex; i < endIndex; i++) {
            QItem storage item = redemptionQueue[i];
            uint256 assetAmount = item.requestedAssets;
            if (totalRequestedAssets + assetAmount > maxAmountUsdt) break;
            totalShares += item.shares;
            totalRequestedAssets += assetAmount;
            totalReservedRedemptionAssets += assetAmount;
            queueRemoteRequestedIndex = i + 1;
        }
        require(totalShares != 0, "NoRedemptionsToRequest");

        uint256 totalNeeded = totalRequestedAssets;
        uint256 amountToRequestFromRemote = totalNeeded > initialAvailableIdle ? totalNeeded - initialAvailableIdle : 0;

        if (amountToRequestFromRemote > 0) {
            _remoteHandleWithdrawRequest(amountToRequestFromRemote); // agent.sendMessage(WITHDRAW, ...)
        }
        return amountToRequestFromRemote;
    }

    // ===================================================================================
    // OriginVault: withdrawFromRemote — OriginVault.sol:472-477 (operator path, second source)
    // ===================================================================================
    function _withdrawFromRemote(uint256 usdtAmount) internal {
        _remoteHandleWithdrawRequest(usdtAmount);
    }

    // ===================================================================================
    // OriginVault: batchFulfillRedemptions — OriginVault.sol:547-596 (verbatim logic)
    // fulfillmentEligibleAssets() = balance - totalFulfilledRedemptionAssets  (OriginVault.sol:333-337)
    // ===================================================================================
    function _batchFulfillRedemptions(uint256 maxAmountUsdt, uint256 maxCount) internal {
        require(maxAmountUsdt != 0, "ZeroMaxAmount");
        uint256 totalShares = 0;
        uint256 totalAssetsUsed = 0;
        uint256 startIndex = queueFulfilledIndex;
        uint256 endIndex =
            queueRemoteRequestedIndex < redemptionQueue.length ? queueRemoteRequestedIndex : redemptionQueue.length;
        endIndex = endIndex - startIndex < maxCount ? endIndex : startIndex + maxCount;

        uint256 availableAssets = originBalance > totalFulfilledRedemptionAssets
            ? originBalance - totalFulfilledRedemptionAssets
            : 0; // fulfillmentEligibleAssets()
        uint256 maxToFulfill = maxAmountUsdt > availableAssets ? availableAssets : maxAmountUsdt;

        for (uint256 i = startIndex; i < endIndex; i++) {
            QItem storage item = redemptionQueue[i];
            uint256 reservedAmount = item.requestedAssets;
            if (totalAssetsUsed + reservedAmount > maxToFulfill) break;

            item.fulfilledAssets = reservedAmount;
            totalShares += item.shares;
            totalAssetsUsed += reservedAmount;

            if (reservedAmount > 0) {
                require(totalReservedRedemptionAssets >= reservedAmount, "ReservedUnderflow");
                totalReservedRedemptionAssets -= reservedAmount;
                item.requestedAssets = 0;
            }
            totalFulfilledRedemptionAssets += reservedAmount;
            queueFulfilledIndex = i + 1;
        }
        require(totalShares != 0, "NoRedemptionsFulfilled");
    }

    // ===================================================================================
    // OriginVault: redeem(requestId) — OriginVault.sol:784-827 (payout leg)
    // ===================================================================================
    function _redeem(uint256 index) internal {
        QItem storage item = redemptionQueue[index];
        require(item.fulfilledAssets != 0, "ZeroAssets");
        require(!item.redeemed, "AlreadyRedeemed");
        uint256 assets = item.fulfilledAssets;
        item.redeemed = true;
        totalFulfilledRedemptionAssets -= assets;
        require(originBalance >= assets, "origin underbalance"); // safeTransfer would revert otherwise
        originBalance -= assets;
        paidOutToUsers += assets;
    }

    // ===================================================================================
    // RemoteVault: handleWithdrawRequest — RemoteVault.sol:675-697 (verbatim logic)
    // ===================================================================================
    function _remoteHandleWithdrawRequest(uint256 neededUsdt) internal {
        uint256 totalAvailableUsdt = remoteUsdt;
        if (totalAvailableUsdt >= neededUsdt) {
            _bridgeAssetsToOrigin(neededUsdt);
            return;
        }
        unfulfilledWithdrawalAmount += neededUsdt;
    }

    // ===================================================================================
    // RemoteVault: fulfillableAmount — RemoteVault.sol:475-481 (verbatim)
    // ===================================================================================
    function _fulfillableAmount() internal view returns (uint256) {
        if (unfulfilledWithdrawalAmount == 0) return 0;
        uint256 available = remoteUsdt;
        return available < unfulfilledWithdrawalAmount ? available : unfulfilledWithdrawalAmount;
    }

    // ===================================================================================
    // RemoteVault: fulfillPendingWithdrawals — RemoteVault.sol:717-726 (verbatim)
    // ===================================================================================
    function _fulfillPendingWithdrawals() internal returns (uint256 fulfilledUsdt) {
        require(unfulfilledWithdrawalAmount != 0, "NoUnfulfilledWithdrawals");
        fulfilledUsdt = _fulfillableAmount();
        require(fulfilledUsdt != 0, "NoAvailableAssets");
        unfulfilledWithdrawalAmount -= fulfilledUsdt;
        _bridgeAssetsToOrigin(fulfilledUsdt);
    }

    // ===================================================================================
    // RemoteVault: _bridgeAssetsToOrigin — RemoteVault.sol:750-766 (asset leaves remote, in transit)
    // ===================================================================================
    function _bridgeAssetsToOrigin(uint256 amount) internal {
        require(amount != 0, "AmountZero");
        require(remoteUsdt >= amount, "InsufficientBalance");
        remoteUsdt -= amount;
        legs.push(Leg({ amount: amount, delivered: false }));
    }

    function _deliverLeg(uint256 i) internal {
        if (legs[i].delivered) return;
        legs[i].delivered = true;
        originBalance += legs[i].amount;
    }

    function _inTransit() internal view returns (uint256 s) {
        for (uint256 i = 0; i < legs.length; i++) {
            if (!legs[i].delivered) s += legs[i].amount;
        }
    }

    function _addRemoteLiquidity(uint256 amount) internal {
        remoteUsdt += amount;
        injectedLiquidity += amount;
    }

    // ===================================================================================
    // Conservation invariant
    // ===================================================================================
    function _system() internal view returns (uint256) {
        return originBalance + remoteUsdt + _inTransit() + paidOutToUsers;
    }

    uint256 internal initialSystem;

    function _snapshotSystem() internal {
        initialSystem = _system();
    }

    function _assertConserved(string memory tag) internal view {
        require(_system() == initialSystem + injectedLiquidity, string(abi.encodePacked("CONSERVATION broken: ", tag)));
    }

    // ===================================================================================
    // Scenario 1 — single redemption, idle 0, normal round-trip
    // ===================================================================================
    function test_S1_normalRoundTrip() public {
        remoteUsdt = 1000;
        originBalance = 0;
        _snapshotSystem();

        _requestRedeem(1000); // user wants 1000 out
        uint256 shortfall = _processRedemptionQueue(type(uint256).max, 10);
        // remote had 1000 >= 1000 -> bridged immediately, unfulfilled stays 0
        assertEq(shortfall, 1000, "S1 shortfall");
        assertEq(unfulfilledWithdrawalAmount, 0, "S1 no unfulfilled");
        _assertConserved("S1-req");

        _deliverLeg(0); // 1000 arrives on origin
        assertEq(originBalance, 1000, "S1 origin bal");

        _batchFulfillRedemptions(type(uint256).max, 10);
        _redeem(0); // pay the user
        assertEq(paidOutToUsers, 1000, "S1 paid");
        _assertConserved("S1-final");
        // user got exactly what was requested, nothing stranded
        assertEq(originBalance, 0, "S1 no residue");
        assertEq(remoteUsdt, 0, "S1 remote drained");
    }

    // ===================================================================================
    // Scenario 2 — DOUBLE SOURCE: processRedemptionQueue + withdrawFromRemote both request,
    // remote cannot fulfill immediately -> unfulfilled doubles -> remote bridges 2x.
    // Question: is the excess LOST, or merely rebalanced to origin (recoverable)?
    // ===================================================================================
    function test_S2_doubleSourceOverBridge() public {
        remoteUsdt = 0; // remote temporarily illiquid
        originBalance = 0;
        _snapshotSystem();

        _requestRedeem(1000);
        uint256 sf = _processRedemptionQueue(type(uint256).max, 10); // unfulfilled += 1000
        assertEq(sf, 1000, "S2 sf");
        _withdrawFromRemote(1000); // operator ALSO requests 1000 -> unfulfilled += 1000
        assertEq(unfulfilledWithdrawalAmount, 2000, "S2 doubled");
        _assertConserved("S2-req");

        // remote gets 2000 liquidity (yearn withdraw)
        _addRemoteLiquidity(2000);
        _fulfillPendingWithdrawals(); // bridges min(2000,2000) = 2000 back to origin
        assertEq(unfulfilledWithdrawalAmount, 0, "S2 cleared");
        _deliverLeg(0);
        assertEq(originBalance, 2000, "S2 origin got 2000");

        // queue only needs 1000
        _batchFulfillRedemptions(type(uint256).max, 10);
        _redeem(0);
        assertEq(paidOutToUsers, 1000, "S2 user got exactly 1000");

        // EXCESS 1000 is NOT lost: it sits as origin idle, fully recoverable / re-deployable.
        assertEq(originBalance, 1000, "S2 excess as idle");
        assertEq(totalReservedRedemptionAssets, 0, "S2 no stuck reservation");
        assertEq(totalFulfilledRedemptionAssets, 0, "S2 no stuck fulfilled");
        _assertConserved("S2-final");
        // Conclusion: over-bridge rebalances liquidity Kaia<-Eth but conserves funds.
        // Requires operator (withdrawFromRemote is onlyOperators) -> OOS under Trust Assumptions.
    }

    // ===================================================================================
    // Scenario 3 — chunked fulfillment: remote fulfills unfulfilled in pieces; never over-bridges.
    // ===================================================================================
    function test_S3_chunkedFulfillNoOverBridge() public {
        remoteUsdt = 0;
        originBalance = 0;
        _snapshotSystem();

        _requestRedeem(1000);
        _processRedemptionQueue(type(uint256).max, 10); // unfulfilled = 1000

        _addRemoteLiquidity(300);
        assertEq(_fulfillableAmount(), 300, "S3 f1");
        _fulfillPendingWithdrawals(); // bridge 300
        assertEq(unfulfilledWithdrawalAmount, 700, "S3 rem");

        _addRemoteLiquidity(700);
        _fulfillPendingWithdrawals(); // bridge 700
        assertEq(unfulfilledWithdrawalAmount, 0, "S3 done");

        // total bridged == 1000 exactly (never more than requested)
        uint256 bridged;
        for (uint256 i = 0; i < legs.length; i++) {
            bridged += legs[i].amount;
        }
        assertEq(bridged, 1000, "S3 exact");
        _assertConserved("S3");
    }

    // ===================================================================================
    // Scenario 4 — fuzz: random interleaving of requests / withdraws / fulfills / deliveries.
    // Assert conservation NEVER breaks and unfulfilled never underflows.
    // ===================================================================================
    function testFuzz_S4_conservation(uint256 seed) public {
        remoteUsdt = 3000;
        originBalance = 500;
        _snapshotSystem();

        uint256 rnd = uint256(keccak256(abi.encode(seed)));
        for (uint256 step = 0; step < 50; step++) {
            rnd = uint256(keccak256(abi.encode(rnd, step)));
            uint256 a = rnd % 6;

            if (a == 0) {
                _requestRedeem(1 + (rnd % 400));
            } else if (a == 1) {
                // process queue if there are unrequested items
                if (queueRemoteRequestedIndex < redemptionQueue.length) {
                    _processRedemptionQueue(type(uint256).max, 1 + (rnd % 3));
                }
            } else if (a == 2) {
                uint256 amt = 1 + (rnd % 800);
                if (remoteUsdt >= 1) _withdrawFromRemote(amt > remoteUsdt + 5000 ? 1 : amt);
            } else if (a == 3) {
                if (unfulfilledWithdrawalAmount != 0 && remoteUsdt != 0) _fulfillPendingWithdrawals();
            } else if (a == 4) {
                if (legs.length > 0) {
                    uint256 start = rnd % legs.length;
                    for (uint256 j = 0; j < legs.length; j++) {
                        uint256 idx = (start + j) % legs.length;
                        if (!legs[idx].delivered) {
                            _deliverLeg(idx);
                            break;
                        }
                    }
                }
            } else {
                _addRemoteLiquidity(1 + (rnd % 300));
            }

            _assertConserved("S4-step");
            // unfulfilled is a uint -> Solidity 0.8 would revert on underflow; explicit sanity:
            assertLe(_fulfillableAmount(), unfulfilledWithdrawalAmount, "S4 fulfillable<=unfulfilled");
        }
        _assertConserved("S4-final");
    }
}
