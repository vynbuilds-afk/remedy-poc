# Remedy PoC — Valantis + AUTOfinance

Runnable Foundry proofs of concept for two Remedy bug bounty reports that
were closed as Spam for "No PoC". The PoCs existed when the reports were
filed but were not attached to the submissions; they are published here so
the triager can clone the repo, run one command per finding, and watch the
exploit happen.

> Note: this repo holds the clean project layout (one folder per finding).
> The raw zip archives were replaced by the extracted projects so each PoC
> can be browsed and run directly.

## Findings

- **Valantis — dust donation flips the swap fee tier** ([valantis-finding-02/](valantis-finding-02/)) — **High**. A 1-wei WETH donation drops the fee on a 100 ETH swap from 500 to 200 bips; the attacker gains **+2.9979 ETH**.
- **AUTOfinance — AutopoolETH.recover() drains the whole vault** ([autofinance-finding-03/](autofinance-finding-03/)) — **High**. The TOKEN_RECOVERY_MANAGER drains **100.0000000000001 WETH to 0 WETH**; the vault stays live and unpaused, and totalAssets() still reports the full amount.

## Reproduce

```bash
git clone https://github.com/vynbuilds-afk/remedy-poc.git
cd remedy-poc/valantis-finding-02 && forge test --match-contract WorkerCPoC -vvvv   # 11 passed
cd ../autofinance-finding-03 && forge test --match-contract AutopoolRecoverPoC -vvvv  # 3 passed
```

Each test logs INITIAL vs FINAL state (fee tier and balances before and
after), so the before/after numbers are the proof. See each folder's README
for the full write-up.

## Targets

- Valantis STEX — scope repo commit `27b5c74` (STEXAMM + stHYPEWithdrawalModule)
- Tokemak v2-core-pub — scope repo commit `de163d5a` (AutopoolETH, Autopool4626)

## Environment

- forge 1.10.0. Valantis PoC verified with solc 0.8.38; AUTOfinance PoC pins
  solc 0.8.17 in foundry.toml. No network needed — all contracts are vendored
  in each folder (src/ byte-identical, lib/ minimal transitive imports only).
