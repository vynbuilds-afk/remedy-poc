# Valantis STEX — dust donation flips the swap fee tier

**Severity: High**

## Bug summary

STEXAMM's constructor passes `true` for both tokens, so the pool's reserves
are the raw ERC20 `balanceOf`. StepwiseFeeModule charges a fee tier from the
post-swap reserves, and the tier is a step function — so a 1-wei WETH
donation made when the post-swap reserves sit exactly at a tier boundary
drops the fee charged on the ENTIRE swap from 500 bips to 200 bips. The
attacker chooses the swap size so the reserves land on the boundary, then
donates 1 wei.

## Root cause

- `STEXAMM.sol` constructor (L143): both reserve flags are `true`, so
  reserves are measured as the pool's raw token balances — anyone can move
  them with a direct transfer.
- `StepwiseFeeModule.getSwapFeeInBips` (L85): the fee tier is read from the
  post-swap reserves, a step function of the reserves, so an infinitesimal
  reserve change at a boundary flips the fee for the whole swap amount.

## Impact (measured)

On a 100 ETH swap (test `test_T6b_FeeTier_DustDonation`, contract
`WorkerCPoC`): baseline fee 500 bips, 95.0028 ETH out; after a 1-wei WETH
donation, fee 200 bips, 98.0007 ETH out — net gain **+2.9979 ETH** for the
attacker, for a 1-wei donation. Repeatable on every swap that lands on a
boundary.

## Reproduce

```bash
cd valantis-finding-02
forge test --match-contract WorkerCPoC -vvvv
```

Expected output: **11 passed, 0 failed**. The T6 tests log the proof:

```
T6a BEFORE: fee tier (bips): 500
T6a BEFORE: amountOut (wei): 95002850085502565076
T6b BEFORE: fee tier (bips): 500
T6b BEFORE: amountOut (wei): 95002800000000000000
T6b AFTER: fee tier (bips): 200
T6b AFTER: amountOut (wei): 98000784006272050176
T6b ATTACKER GAIN (wei): 2997984006272050176
```

The other tests (T1–T5) are negative controls / regression tests for the
other angles checked during the audit: swap-callback surplus theft is
blocked, flash loans are disabled for both tokens, the queue priority bypass
is fixed, reentrant claims gain nothing, and plain donation / round-trip /
sandwich cases lose money. Only the tier-boundary dust donation is
profitable.

## Environment

Standalone Foundry project, no network needed. Tested with forge 1.10.0.
The project pins evm_version cancun and the optimizer (10,000 runs) in
foundry.toml; no solc version is pinned, forge uses its default solc
(verified with solc 0.8.38).

## Contents

`test/WorkerCPoC.t.sol` plus the production contracts it exercises
(`src/STEXAMM.sol`, `src/swap-fee-modules/StepwiseFeeModule.sol` and the
contracts they import), vendored byte-identical from the in-scope Valantis
repository (scope commit `27b5c74`), together with the libraries they need
(valantis-core, solmate, openzeppelin-contracts, forge-std). All remappings
in `remappings.txt` are relative paths inside this folder.
