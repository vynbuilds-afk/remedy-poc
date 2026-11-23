# UFarm — performance fee charged on just-minted AUM fee shares

**Severity: High**

## Bug summary

At every settlement, `VaultLifecycleModule._previewFeeAccrual` mints the
protocol and management (AUM) fee shares FIRST, enlarging the supply from
`S0` to `S1 = S0 + A`, and then computes the performance fee on the enlarged
supply. The code charges `rate * (p1 - HWM) * S1`, while the cash-fee
equivalent benchmark charges the per-share profit only on the investor
shares that actually earned it: `rate * (p1 - HWM) * S0`. The excess —
`rate * (p1 - HWM) * A` — is a performance fee on the unrealised gain of
the curator/protocol's own just-minted fee shares. The AUM fees are
deducted from profit only at the OLD high-water-mark price (`HWM * A`),
not at their true current value (`p1 * A`).

## Root cause

- `VaultLifecycleModule._previewFeeAccrual`
  (`contracts/vault/modules/VaultLifecycleModule.sol:774`): the AUM fee
  shares are minted first (protocol fee on `startingSupply`, management
  fee on the enlarged supply), and the performance-fee call at L796 passes
  `supplyAfterAum` — not `startingSupply` — to
  `FeeMath.performanceFeeShares`.
- `FeeMath.performanceFeeShares`
  (`contracts/libraries/FeeMath.sol:51`): uses that `supply` as the
  multiplier for every tier slice (`sliceValue = (upperPrice - lowerPrice)
  * supply / WAD`), so the fee recipients' own fee shares are charged a
  performance fee on their own gain.

The minted excess shares go 20% to the protocol and 80% to the curator,
both of whom can redeem them, so the diversion is permanent and
realisable. No attacker is needed: the protocol's own settlement flow
does it, on every settlement, forever, on every vault with nonzero AUM
fees and gains above the high-water mark.

## Impact (measured)

Test `testOverchargeWithManagementFee` (contract `FeeOverchargeTest`),
scenario `S0 = 1000e18` shares, `HWM = 1e18`, `NAV = 2000e18` (price 2x),
365 days elapsed, 10% management fee, 20% single-step performance fee:

- AUM fee shares minted: **111.111e18**; post-AUM share price `p1`: **1.8e18**
- Code performance fee value: **177.778e18**; correct value: **160e18**
- Excess: **17.778e18 = 11.1% overcharge**, every settlement

Worked dollar example: a $10M vault earning 30% above HWM with a 20%
performance fee and 20% aggregate annual AUM fees over-charges roughly
**~$25k of yield per year** to curator/protocol (correct perf fee
$106,000 vs code $130,864; excess $24,864/yr). The other tests confirm
the mechanism: protocol-fee-only shows the same overcharge; with no AUM
fees the code equals the benchmark exactly; with no gain above HWM no
performance fee is charged.

## Caveats (stated honestly)

- **UFARM1-6 connection.** This is the same issue family as ABS May 2025
  UFARM1-6 ("AUM fee not deducted from profit", Medium, Fixed): the v1
  defect charged the fee with NO AUM deduction at all (200e18); the v2
  code changed the mechanism (AUM fees now dilute the price first) but
  leaves a distinct residual defect (177.78e18 vs the correct 160e18).
  A triager could still mark it a duplicate of UFARM1-6 — roughly a
  50/50 call. The numbers above prove the residual is a different
  formula, not the v1 bug and not the correct one.
- **Downgrade risk.** A triager could view this as a fee-accounting
  imprecision and rate it Medium. Counter: no documentation states the
  performance fee is assessed on fee shares, and the v1 audit's UFARM1-6
  fix shows the intended semantics is deduction of AUM fees from profit —
  which this code does only partially.

## Reproduce

```bash
cd ufarm-finding-01
forge test --match-contract FeeOverchargeTest -vvvv
```

Expected output: **4 passed, 0 failed**. The main test logs the proof:

```
BEFORE: investor shares S0 (wei): 1000000000000000000000
BEFORE: AUM fee shares minted (wei): 111111111111111111111
BEFORE: supply after AUM fees S1 (wei): 1111111111111111111111
BEFORE: post-AUM share price p1 (wei): 1800000000000000000
CODE perf fee value (wei): 177777777777777777776
CORRECT perf fee value (wei): 160000000000000000000
EXCESS perf fee value (wei): 17777777777777777776
EXCESS perf fee shares (wei): 11782726522917403086
```

## Environment

Standalone Foundry project, no network needed. Tested with forge 1.10.0,
solc 0.8.35 (pinned in foundry.toml). No forge-std dependency in the
original PoC; only `forge-std/console.sol` is vendored for the log lines.

## Contents

`test/FeeOvercharge.t.sol` plus `src/FeeMathReimpl.sol` — a from-scratch
**reimplementation** of the fee arithmetic in `FeeMath.sol` +
`VaultLifecycleModule._previewFeeAccrual`, transcribed from reading those
files at scope HEAD `b19a651` ("Production Release 2.1.1") and checked
line-by-line against the originals during the audit. It imports nothing
from the audited repo, so the project is fully standalone. The production
code the PoC models is quoted in the PDF attached to the Remedy thread
reply (`VaultLifecycleModule._previewFeeAccrual` L774-803 and
`FeeMath.performanceFeeShares` L51-90).
