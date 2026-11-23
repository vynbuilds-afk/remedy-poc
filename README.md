# Remedy PoC — Valantis, AUTOfinance + UFarm

Runnable Foundry proofs of concept for four Remedy bug bounty reports.
Two were closed as Spam for "No PoC" (Valantis F-02, AUTOfinance F-03) —
the PoCs existed when the reports were filed but were not attached to the
submissions. Two more (UFarm F-01, UFarm F-02) are still open and
untriaged; their PoCs are published here ahead of triage so the triager
can verify them. Clone the repo, run one command per finding, and watch
the exploit happen.

> Note: this repo holds the clean project layout (one folder per finding).
> The raw zip archives were replaced by the extracted projects so each PoC
> can be browsed and run directly.

## Findings

- **Valantis — dust donation flips the swap fee tier** ([valantis-finding-02/](valantis-finding-02/)) — **High**. A 1-wei WETH donation drops the fee on a 100 ETH swap from 500 to 200 bips; the attacker gains **+2.9979 ETH**.
- **AUTOfinance — AutopoolETH.recover() drains the whole vault** ([autofinance-finding-03/](autofinance-finding-03/)) — **High**. The TOKEN_RECOVERY_MANAGER drains **100.0000000000001 WETH to 0 WETH**; the vault stays live and unpaused, and totalAssets() still reports the full amount.
- **UFarm — performance fee charged on just-minted AUM fee shares** ([ufarm-finding-01/](ufarm-finding-01/)) — **High**. The code charges 177.778e18 where the correct charge is 160e18 — an excess of 17.778e18, an 11.1% overcharge, roughly $25k of yield per year on a $10M vault.
- **UFarm — EIP-712 array-shift guard bypass** ([ufarm-finding-02/](ufarm-finding-02/)) — **High**. A short op stream skips the trailing directive constraint: a 1-element path with minOut=0 returns a valid EIP-712 digest for a whitelisted Swap directive that requires minOut EXACT 1000.

## Reproduce

```bash
git clone https://github.com/vynbuilds-afk/remedy-poc.git
cd remedy-poc/valantis-finding-02 && forge test --match-contract WorkerCPoC -vvvv   # 11 passed
cd ../autofinance-finding-03 && forge test --match-contract AutopoolRecoverPoC -vvvv  # 3 passed
cd ../ufarm-finding-01 && forge test -vvvv  # 4 passed
cd ../ufarm-finding-02 && forge test --match-contract EIP712ArrayShiftPoC -vvvv  # 4 passed
```

Each test logs INITIAL vs FINAL state (fee tier and balances before and
after), so the before/after numbers are the proof. See each folder's README
for the full write-up.

## Targets

- Valantis STEX — scope repo commit `27b5c74` (STEXAMM + stHYPEWithdrawalModule)
- Tokemak v2-core-pub — scope repo commit `de163d5a` (AutopoolETH, Autopool4626)
- UFarm-EVM-Contracts — scope repo commit `b19a6511c61157bfd68df1c28f0299e68bde02fb` ("Production Release 2.1.1")

## Environment

- forge 1.10.0. Valantis PoC verified with solc 0.8.38; AUTOfinance PoC pins
  solc 0.8.17 in foundry.toml; UFarm PoCs pin solc 0.8.35 in foundry.toml.
  No network needed — all contracts are vendored in each folder (src/
  byte-identical, lib/ minimal transitive imports only; the UFarm F-01 PoC
  is a from-scratch reimplementation of the fee arithmetic — see its README).
