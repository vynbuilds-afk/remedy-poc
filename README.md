# Remedy PoC — Valantis + AUTOfinance

Runnable Foundry proofs of concept for two bug bounty reports that were
closed as Spam for "No PoC". The PoCs existed when the reports were filed
but were not attached to the submissions; they are published here so the
triager can download and run them.

> Note: this repo contains the clean project layout (one folder per
> finding). The raw zip archives were replaced by the extracted projects so
> each PoC can be browsed and run directly.

## Contents

- `valantis-finding-02/` — Valantis STEXAMM dust-donation fee-tier bypass (High)
- `autofinance-finding-03/` — AUTOfinance AutopoolETH.recover() vault drain (High)

## Valantis — dust donation flips the swap fee tier

STEXAMM reserves are the raw token `balanceOf`, so a 1-wei WETH donation
made when the post-swap reserves sit exactly at a stepwise fee-tier boundary
drops the fee charged on the entire swap from 500 bips to 200 bips.
Measured on a 100 ETH swap: baseline 500 bips, 95.0028 ETH out; after the
1-wei donation, 200 bips, 98.0007 ETH out — net +2.9979 ETH for the attacker.

Run: `cd valantis-finding-02 && forge test` (forge 1.10.0, solc 0.8.38).
All 11 tests pass.

## AUTOfinance — AutopoolETH.recover() drains the whole vault

`AutopoolETH.recover()` lets the TOKEN_RECOVERY_MANAGER drain the entire
vault, because the tracked-asset exclusion guard in `Autopool4626.recover`
was commented out in commit 9a19d48e (2024-05-28) and never restored.
Measured: a vault holding 100.0000000000001 WETH is drained to 0 WETH by a
single `recover()` call. The vault stays live and unpaused afterwards, and
`totalAssets()` still reports the full amount.

Run: `cd autofinance-finding-03 && forge test` (forge 1.10.0, solc 0.8.17).
All 3 tests pass. A second, independent PoC of the same drain
(`RecoverDrainPoC.t.sol`, 3/3 pass) is not included here.
