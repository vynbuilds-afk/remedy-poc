// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FeeMathReimpl, PreviewReimpl} from "../src/FeeMathReimpl.sol";
import {console} from "forge-std/console.sol";

/// @title UFarm — performance fee charged on just-minted AUM fee shares
///
/// Bug: VaultLifecycleModule._previewFeeAccrual mints the protocol and
/// management (AUM) fee shares FIRST (supply S0 -> S1), then computes the
/// performance fee on the enlarged supply S1, so the curator/protocol earn
/// a performance fee on the unrealised gain of their own just-minted fee
/// shares. The AUM fees are deducted from profit only at the OLD
/// high-water-mark price, not at their true current value.
/// Impact: every vault with nonzero AUM fees that rises above its
/// high-water mark systematically overcharges investors on every
/// settlement; the excess is minted as redeemable shares, 20% to the
/// protocol and 80% to the curator. Measured: code fee 177.778e18 vs
/// correct 160e18 (excess 17.778e18, 11.1% overcharge) on S0 = 1000e18,
/// HWM = 1e18, NAV = 2000e18; ~$25k/yr excess on a $10M vault earning
/// 30% above HWM with a 20% performance fee.
/// Severity: High
/// Affected: UFarm-EVM-Contracts commit b19a6511c61157bfd68df1c28f0299e68bde02fb
/// ("Production Release 2.1.1"), contracts/vault/modules/VaultLifecycleModule.sol
/// _previewFeeAccrual L774 (performance-fee call L796),
/// contracts/libraries/FeeMath.sol performanceFeeShares L51.
contract FeeOverchargeTest {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    event Numbers(
        string scenario,
        uint256 supplyBefore,
        uint256 aumShares,
        uint256 supplyAfterAum,
        uint256 postAumPrice,
        uint256 codeFeeValue,
        uint256 correctFeeValue,
        uint256 excessFeeValue,
        uint256 codePerfShares,
        uint256 correctPerfShares
    );

    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }

    /// @dev Single-step schedule: 20% fee, threshold = MAX (0xFFFF, "infinity").
    function schedule20() internal pure returns (uint256) {
        return uint256(2000) | (uint256(0xFFFF) << 16);
    }

    /// @dev Recompute the code's fee VALUE from its fee shares:
    /// feeShares = feeValue * S1 / (NAV - feeValue)  =>  feeValue = feeShares * NAV / (S1 + feeShares)
    function feeValueFromShares(uint256 feeShares, uint256 nav, uint256 s1) internal pure returns (uint256) {
        if (feeShares == 0) return 0;
        return mulDiv(feeShares, nav, s1 + feeShares);
    }

    /// @dev Correct (cash-equivalent) performance fee, converted to shares with
    /// the same minting formula the code uses, so the comparison isolates the
    /// fee VALUE difference.
    function correctPerfShares(uint256 nav, uint256 s0, uint256 s1, uint256 hwm, uint256 feeBps)
        internal
        pure
        returns (uint256 feeShares, uint256 feeValue)
    {
        uint256 p1 = mulDiv(nav, WAD, s1);
        if (p1 <= hwm) return (0, 0);
        uint256 sliceValue = mulDiv(p1 - hwm, s0, WAD);
        feeValue = mulDiv(sliceValue, feeBps, BPS);
        if (feeValue == 0) return (0, 0);
        feeShares = mulDiv(feeValue, s1, nav - feeValue);
    }

    function testOverchargeWithManagementFee() public {
        uint256 s0 = 1000e18;
        uint256 hwm = 1e18;
        uint256 nav = 2000e18; // share price doubled to 2.0 before fees
        uint256 elapsed = 365 days;
        PreviewReimpl.Accrual memory acc =
            PreviewReimpl.preview(nav, s0, 0, 0.1e18, elapsed, hwm, schedule20());

        require(acc.aumShares > 0, "expected nonzero AUM shares");
        require(acc.grossSharePrice > hwm, "expected price above HWM");
        (uint256 corrShares, uint256 corrValue) =
            correctPerfShares(nav, s0, acc.supplyAfterAum, hwm, 2000);
        uint256 codeValue = feeValueFromShares(acc.performanceFeeShares, nav, acc.supplyAfterAum);

        console.log("BEFORE: investor shares S0 (wei):", s0);
        console.log("BEFORE: AUM fee shares minted (wei):", acc.aumShares);
        console.log("BEFORE: supply after AUM fees S1 (wei):", acc.supplyAfterAum);
        console.log("BEFORE: post-AUM share price p1 (wei):", acc.grossSharePrice);
        console.log("CODE perf fee value (wei):", codeValue);
        console.log("CORRECT perf fee value (wei):", corrValue);
        console.log("EXCESS perf fee value (wei):", codeValue - corrValue);
        console.log("EXCESS perf fee shares (wei):", acc.performanceFeeShares - corrShares);
        emit Numbers(
            "mgmt-10pct-1yr-price-2x",
            s0,
            acc.aumShares,
            acc.supplyAfterAum,
            acc.grossSharePrice,
            codeValue,
            corrValue,
            codeValue - corrValue,
            acc.performanceFeeShares,
            corrShares
        );

        // (1) Code charges strictly more than the cash-equivalent benchmark.
        require(acc.performanceFeeShares > corrShares, "FAIL: no overcharge");
        require(codeValue > corrValue, "FAIL: no excess value");
        // (2) Excess equals rate * (p1 - HWM) * AUM shares (within rounding).
        uint256 expectedExcess =
            mulDiv(mulDiv(acc.grossSharePrice - hwm, acc.aumShares, WAD), 2000, BPS);
        uint256 excess = codeValue - corrValue;
        require(
            excess >= expectedExcess && excess - expectedExcess <= 1e9
                || expectedExcess >= excess && expectedExcess - excess <= 1e9,
            "FAIL: excess != rate*(p1-HWM)*AUM"
        );
        // (3) The deduction the code effectively makes for AUM fees is only
        // HWM * AUM (not current-price p1 * AUM): code fee value equals
        // rate * (NAV - HWM*(S0+AUM)), i.e. profit net of HWM-valued fees.
        uint256 profitNetOfHwmValuedFees = nav - mulDiv(hwm, acc.supplyAfterAum, WAD);
        uint256 codeFeeImplied = mulDiv(profitNetOfHwmValuedFees, 2000, BPS);
        require(
            codeValue >= codeFeeImplied && codeValue - codeFeeImplied <= 1e9
                || codeFeeImplied >= codeValue && codeFeeImplied - codeValue <= 1e9,
            "FAIL: code fee != rate*(NAV - HWM*S1)"
        );
        // (4) Scale: excess is ~10% of the correct fee here (AUM/S0 ~ 11%).
        require(excess * 100 > corrValue * 5, "FAIL: excess too small to matter");
    }

    function testOverchargeWithProtocolFeeOnly() public {
        uint256 s0 = 1000e18;
        uint256 hwm = 1e18;
        uint256 nav = 2000e18;
        PreviewReimpl.Accrual memory acc =
            PreviewReimpl.preview(nav, s0, 0.1e18, 0, 365 days, hwm, schedule20());
        (uint256 corrShares, uint256 corrValue) =
            correctPerfShares(nav, s0, acc.supplyAfterAum, hwm, 2000);
        uint256 codeValue = feeValueFromShares(acc.performanceFeeShares, nav, acc.supplyAfterAum);
        emit Numbers(
            "protocol-10pct-1yr-price-2x",
            s0,
            acc.aumShares,
            acc.supplyAfterAum,
            acc.grossSharePrice,
            codeValue,
            corrValue,
            codeValue - corrValue,
            acc.performanceFeeShares,
            corrShares
        );
        require(acc.performanceFeeShares > corrShares, "FAIL: no overcharge (protocol fee)");
    }

    function testNoOverchargeWithoutAumFees() public {
        uint256 s0 = 1000e18;
        uint256 hwm = 1e18;
        uint256 nav = 2000e18;
        PreviewReimpl.Accrual memory acc =
            PreviewReimpl.preview(nav, s0, 0, 0, 365 days, hwm, schedule20());
        require(acc.aumShares == 0, "expected zero AUM shares");
        (uint256 corrShares, uint256 corrValue) =
            correctPerfShares(nav, s0, acc.supplyAfterAum, hwm, 2000);
        uint256 codeValue = feeValueFromShares(acc.performanceFeeShares, nav, acc.supplyAfterAum);
        emit Numbers(
            "no-aum-fees-control",
            s0,
            acc.aumShares,
            acc.supplyAfterAum,
            acc.grossSharePrice,
            codeValue,
            corrValue,
            codeValue >= corrValue ? codeValue - corrValue : 0,
            acc.performanceFeeShares,
            corrShares
        );
        // Control: with no AUM shares, S1 == S0, so code == benchmark exactly.
        require(acc.performanceFeeShares == corrShares, "FAIL: control mismatch");
    }

    function testNoPerfFeeWithoutGain() public pure {
        uint256 s0 = 1000e18;
        uint256 hwm = 1e18;
        uint256 nav = 1000e18; // price == HWM
        PreviewReimpl.Accrual memory acc =
            PreviewReimpl.preview(nav, s0, 0, 0.1e18, 365 days, hwm, schedule20());
        require(acc.performanceFeeShares == 0, "FAIL: perf fee charged with no gain");
        require(acc.managementFeeShares > 0, "expected mgmt fee still accrues");
    }
}
