# AUTOfinance / Tokemak — AutopoolETH.recover() drains the whole vault

**Severity: High**

## Bug summary

`AutopoolETH.recover()` lets the TOKEN_RECOVERY_MANAGER drain the entire
vault. The tracked-asset exclusion guard in `Autopool4626.recover` was
commented out in commit `9a19d48e` (2024-05-28, "temporarily remove recover
restrictions") and never restored; the matching unit tests were commented out
too. `DestinationVault.recover()` still enforces the guard — Autopool is the
inconsistent outlier.

## Root cause

- `AutopoolETH.recover()` (`src/vault/AutopoolETH.sol:777`) calls
  `Autopool4626.recover()` (`src/vault/libs/Autopool4626.sol:145`).
- The guard that reverted with `Errors.AssetNotAllowed` when the token was
  the vault itself, `autoPool.asset()`, a registered destination, or a
  destination queued for removal (L159–168) is commented out, so `recover()`
  transfers ANY token held by the vault — including its own base asset — to
  an arbitrary destination.

## Impact (measured)

Test `test_RecoveryManagerDrainsWholeVault` (contract `AutopoolRecoverPoC`):
a vault holding **100.0000000000001 WETH** is drained to **0 WETH** by two
`recover()` calls from the TOKEN_RECOVERY_MANAGER (who holds no admin or
manager role). The vault stays live and unpaused afterwards, the user keeps
their shares, and `totalAssets()` still reports the full amount (silent
drain, stale NAV).

## Reproduce

```bash
cd autofinance-finding-03
forge test --match-contract AutopoolRecoverPoC -vvvv
```

Expected output: **3 passed, 0 failed**. The drain test logs the proof:

```
BEFORE: vault WETH (wei): 100000000000000100000
BEFORE: attacker WETH (wei): 0
BEFORE: totalAssets (wei): 100000000000000100000
AFTER 1st recover: vault WETH (wei): 100000
AFTER 1st recover: attacker WETH (wei): 100000000000000000000
AFTER 2nd recover: vault WETH (wei): 0
AFTER 2nd recover: attacker WETH (wei): 100000000000000100000
AFTER 2nd recover: totalAssets (wei, stale): 100000000000000100000
AFTER 2nd recover: vault paused: false
AFTER 2nd recover: vault shutdown: false
```

## Environment

Standalone Foundry project, no network needed. Tested with forge 1.10.0,
solc 0.8.17 (pinned in foundry.toml), evm_version shanghai, optimizer
200 runs.

## Contents

`test/RecoverPoC.t.sol` plus the production contracts it exercises
(AutopoolETH, AutopoolRegistry, SystemRegistry, AccessController,
SystemSecurityL1 and the vault libraries), vendored byte-identical from the
in-scope Tokemak v2-core repository (scope commit `de163d5a`), together with
the libraries they need (openzeppelin-contracts, forge-std, ds-test).
All remappings in `remappings.txt` are relative paths inside this folder.

Note: a second, independent PoC of the same drain (`RecoverDrainPoC.t.sol`,
3/3 pass, built on the repo's own AutopoolETHTests harness) exists but is
not included here; it confirms the same result.
