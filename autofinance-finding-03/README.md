# Proof of Concept — AUTOfinance / Tokemak: AutopoolETH.recover() drains the whole vault

Finding (High): AutopoolETH.recover() lets the TOKEN_RECOVERY_MANAGER drain
the whole vault. The tracked-asset exclusion guard in Autopool4626.recover
was commented out in commit 9a19d48e (2024-05-28, "temporarily remove recover
restrictions") and never restored; the matching unit tests were commented out
too. DestinationVault.recover() still enforces the guard — Autopool is the
inconsistent outlier.

## What this PoC proves (contract AutopoolRecoverPoC, test/RecoverPoC.t.sol, 3/3 pass)

- test_RecoveryManagerDrainsWholeVault: a vault holding
  100.0000000000001 WETH is drained to 0 WETH by a single recover() call
  from the TOKEN_RECOVERY_MANAGER.
- The vault stays live and unpaused after the drain, and totalAssets()
  still reports the full amount (silent drain, stale NAV).
- test_NonRoleCallerReverts: a caller without the role still reverts, so
  the issue is the missing tracked-asset guard, not missing access control.

## How to run (standalone Foundry project, no network needed)

1. `cd` into this folder.
2. Run: `forge test` (or only this PoC: `forge test --match-contract AutopoolRecoverPoC`)
3. Expect: 3 passed, 0 failed.

Tested with forge 1.10.0, solc 0.8.17 (pinned in foundry.toml),
evm_version shanghai, optimizer 200 runs.

## Contents

test/RecoverPoC.t.sol plus the production contracts it exercises
(AutopoolETH, AutopoolRegistry, SystemRegistry, AccessController,
SystemSecurityL1 and the vault libraries), vendored byte-identical from the
in-scope Tokemak v2-core repository (scope commit de163d5a), together with
the libraries they need (openzeppelin-contracts, forge-std, ds-test).
All remappings in remappings.txt are relative paths inside this folder.

Note: a second, independent PoC of the same drain (RecoverDrainPoC.t.sol,
3/3 pass, built on the repo's own AutopoolETHTests harness) exists but is
not included here; it confirms the same result.
