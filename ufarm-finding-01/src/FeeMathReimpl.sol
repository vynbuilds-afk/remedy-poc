// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice REIMPLEMENTATION (not a copy) of the fee arithmetic in
/// UFarm FeeMath.sol + VaultLifecycleModule._previewFeeAccrual, transcribed
/// from reading those files at scope HEAD b19a651 ("Production Release 2.1.1").
/// Written from scratch here so the PoC project is fully standalone and
/// imports nothing from the audited repo. All formulas were checked
/// line-by-line against the originals during the audit (see WORK-LOG.md).
/// Plain uint256 arithmetic is used (no OZ dependency); magnitudes stay far
/// below 2**256 in the tested scenarios.
library FeeMathReimpl {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant PROTOCOL_SPLIT = 0.2e18;
    uint256 internal constant MAX_PERIOD_FEE = 0.5e18;
    uint256 internal constant PERFORMANCE_FEE_BPS_CAP = 5_000;
    uint256 internal constant PERFORMANCE_FEE_STEPS = 4;
    uint256 internal constant PERFORMANCE_FEE_STEP_BITS = 32;
    uint256 internal constant PERFORMANCE_FEE_STEP_MASK = 0xffffffff;
    uint256 internal constant PERFORMANCE_FEE_FIELD_MASK = 0xffff;
    uint256 internal constant PERFORMANCE_FEE_MAX_THRESHOLD_BPS = type(uint16).max;

    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }

    function aumFeeShares(uint256 supply, uint256 annualFee, uint256 elapsed) internal pure returns (uint256) {
        if (supply == 0 || annualFee == 0 || elapsed == 0) return 0;
        uint256 periodFee = mulDiv(annualFee, elapsed, YEAR);
        if (periodFee > MAX_PERIOD_FEE) periodFee = MAX_PERIOD_FEE;
        return mulDiv(supply, periodFee, WAD - periodFee);
    }

    function performanceFeeShares(uint256 nav, uint256 supply, uint256 highWaterMark, uint256 schedule)
        internal
        pure
        returns (uint256 feeShares, uint256 sharePrice)
    {
        if (supply == 0) return (0, 0);
        sharePrice = mulDiv(nav, WAD, supply);
        if (schedule == 0 || sharePrice <= highWaterMark) return (0, sharePrice);

        uint256 lowerPrice = highWaterMark;
        uint256 feeValue = 0;
        for (uint256 i = 0; i < PERFORMANCE_FEE_STEPS; ++i) {
            uint256 step = (schedule >> (i * PERFORMANCE_FEE_STEP_BITS)) & PERFORMANCE_FEE_STEP_MASK;
            uint256 feeBps = step & PERFORMANCE_FEE_FIELD_MASK;
            uint256 thresholdBps = (step >> 16) & PERFORMANCE_FEE_FIELD_MASK;
            uint256 upperPrice = thresholdBps == PERFORMANCE_FEE_MAX_THRESHOLD_BPS
                ? sharePrice
                : highWaterMark + mulDiv(highWaterMark, thresholdBps, BPS);
            if (upperPrice > sharePrice) upperPrice = sharePrice;

            if (upperPrice > lowerPrice && feeBps != 0) {
                uint256 sliceValue = mulDiv(upperPrice - lowerPrice, supply, WAD);
                feeValue += mulDiv(sliceValue, feeBps, BPS);
            }
            if (thresholdBps == PERFORMANCE_FEE_MAX_THRESHOLD_BPS || upperPrice == sharePrice) break;
            lowerPrice = upperPrice;
        }

        if (feeValue == 0) return (0, sharePrice);
        uint256 maxFeeValue = nav / 2;
        if (feeValue > maxFeeValue) feeValue = maxFeeValue;

        feeShares = mulDiv(feeValue, supply, nav - feeValue);
    }

    function splitCuratorFee(uint256 shares, bool zeroUFarmFee)
        internal
        pure
        returns (uint256 protocolCut, uint256 curatorCut)
    {
        if (zeroUFarmFee) return (0, shares);
        protocolCut = mulDiv(shares, PROTOCOL_SPLIT, WAD);
        curatorCut = shares - protocolCut;
    }
}

/// @notice Mirrors VaultLifecycleModule._previewFeeAccrual sequencing:
/// protocol AUM fee first, then management AUM fee on the enlarged supply,
/// then performance fee on (nav, supplyAfterAum, HWM, schedule).
library PreviewReimpl {
    struct Accrual {
        uint256 protocolShares;
        uint256 curatorShares;
        uint256 protocolFeeShares;
        uint256 managementFeeShares;
        uint256 performanceFeeShares;
        uint256 grossSharePrice;
        uint256 supplyAfterAum;
        uint256 aumShares;
    }

    function preview(
        uint256 nav,
        uint256 startingSupply,
        uint256 protocolFee,
        uint256 managementFee,
        uint256 elapsed,
        uint256 highWaterMark,
        uint256 schedule
    ) internal pure returns (Accrual memory accrual) {
        if (startingSupply == 0) return accrual;
        accrual.protocolFeeShares = FeeMathReimpl.aumFeeShares(startingSupply, protocolFee, elapsed);
        uint256 supplyAfterProtocol = startingSupply + accrual.protocolFeeShares;
        accrual.managementFeeShares =
            FeeMathReimpl.aumFeeShares(supplyAfterProtocol, managementFee, elapsed);
        (uint256 mgmtProtocolCut, uint256 mgmtCuratorCut) =
            FeeMathReimpl.splitCuratorFee(accrual.managementFeeShares, false);
        uint256 supplyAfterAum = supplyAfterProtocol + accrual.managementFeeShares;
        accrual.supplyAfterAum = supplyAfterAum;
        accrual.aumShares = accrual.protocolFeeShares + accrual.managementFeeShares;
        (accrual.performanceFeeShares, accrual.grossSharePrice) =
            FeeMathReimpl.performanceFeeShares(nav, supplyAfterAum, highWaterMark, schedule);
        (uint256 perfProtocolCut, uint256 perfCuratorCut) =
            FeeMathReimpl.splitCuratorFee(accrual.performanceFeeShares, false);
        accrual.protocolShares = accrual.protocolFeeShares + mgmtProtocolCut + perfProtocolCut;
        accrual.curatorShares = mgmtCuratorCut + perfCuratorCut;
    }
}
