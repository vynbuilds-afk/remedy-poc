# Proof of Concept — Valantis STEX: dust donation flips the swap fee tier

Finding (High): the STEXAMM constructor passes `true` for both tokens, so the
pool's reserves are the raw ERC20 balanceOf. A 1-wei WETH donation made when
the post-swap reserves sit exactly at a stepwise fee-tier boundary drops the
fee charged on the ENTIRE swap from 500 bips to 200 bips. The attacker chooses
the swap size so the reserves land on the boundary, then donates 1 wei.

## What this PoC proves (contract WorkerCPoC, test/WorkerCPoC.t.sol, 11/11 pass)

- T6a baseline: 100 ETH swap, fee 500 bips, 95.0028 ETH out.
- T6b after a 1-wei WETH donation: same 100 ETH swap, fee 200 bips,
  98.0007 ETH out.
- Net gain for the attacker: +2.9979 ETH on a single 100 ETH swap.
- The other tests (T1-T5) are negative controls: swap-callback surplus
  theft is blocked, flash loans are disabled for both tokens, the queue
  priority bypass is fixed, reentrant claims gain nothing, and plain
  donation / round-trip / sandwich cases lose money. Only the tier-boundary
  dust donation is profitable.

## How to run (standalone Foundry project, no network needed)

1. `cd` into this folder.
2. Run: `forge test` (or only this PoC: `forge test --match-contract WorkerCPoC`)
3. Expect: 11 passed, 0 failed.

Tested with forge 1.10.0. The project pins evm_version cancun and the
optimizer (10,000 runs) in foundry.toml; no solc version is pinned, forge
uses its default solc (verified with solc 0.8.38).

## Contents

test/WorkerCPoC.t.sol plus the production contracts it exercises
(src/STEXAMM.sol, src/swap-fee-modules/StepwiseFeeModule.sol and the
contracts they import), vendored byte-identical from the in-scope Valantis
repository (scope commit 27b5c74), together with the libraries they need
(valantis-core, solmate, openzeppelin-contracts, forge-std). All remappings
in remappings.txt are relative paths inside this folder.
