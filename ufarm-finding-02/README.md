# UFarm — EIP-712 array-shift guard bypass: short op stream skips trailing directive constraints

**Severity: High**

## Bug summary

`ArbitraryAdapterGuard.eip712Hash()` matches an EIP-712 op stream against
whitelisted `SignDirective`s positionally, using one global `fieldCount`
that increments for every typehash word and every `FIELD` op and is never
reset per struct/array. There is **no check that all of a directive's
headers were consumed** (no `fieldCount == directive.length` check).
`_matchSignDirective()` only *skips* a directive when the stream is LONGER
than it; when the stream is SHORTER, the directive's trailing headers are
simply never evaluated — yet the directive can still "match".

A variable-length array makes the stream shorter in a way the target dapp
still accepts: the array's hash commits to its actual (shorter) contents,
so the digest the guard returns is the *valid* EIP-712 digest of the
shortened message. Fields after the array shift left onto earlier,
permissive `TYPE_ANY` headers, and the trailing `TYPE_EXACT` constraint is
skipped.

## Root cause

- `ArbitraryAdapterGuard.eip712Hash`
  (`contracts/adapters/ArbitraryAdapterGuard.sol:224`): builds the match
  state and only checks `len == idx`, `depth == 0`, `rootHash != 0`, and
  `matchedDirectives == 0 -> return 0`. **No comparison of the consumed
  field count against any directive's length.**
- `_matchSignDirective` (L374): `if (fieldIdx >=
  dirs[idx].directives.length) continue;` — a directive that runs out of
  headers contributes no bit, so a LONGER stream kills it, but a SHORTER
  stream never reaches its trailing headers and they are never evaluated.
- `_eip712BeginStruct` / `_eip712Field` (L429 / L465): both increment the
  single global `state.fieldCount`. Array elements each consume one field
  position, so array length directly shifts the alignment of every later
  field.

The protocol-call side (`isProtocolAllowed()` / `_matchDirective()`) does
NOT have this flaw: it requires `payloadLength == payload.length`
exactly. Only the EIP-712 path is affected.

## Impact (measured)

Whitelisted directive for `Swap(address[] path, uint256 minOut)`, 3-element
path, `minOut` EXACT 1000 — headers `[EXACT(typehash), ANY, ANY, ANY,
EXACT(minOut=1000)]`, dictionary `typehash || 1000`:

- Honest message (path 3 elems, minOut=1000): **allowed**, digest equals
  the independently computed EIP-712 digest.
- Control (path 3 elems, minOut=0): **rejected** (guard returns 0) — the
  full-length constraint works.
- **Bypass (path 1 elem, minOut=0): guard returns a non-zero digest**
  `0xfee92ac7b18d03354863e22836782e4bc49b3e77697081857b3f8b5d903eae23`,
  **equal to the independently computed EIP-712 digest of the violating
  message** — a conforming target dapp would accept the vault's signature
  over it.
- **Bypass (path 0 elems, minOut=0): same**, digest
  `0x789624ac7de033ba6dafdcbef8d8ab9bc8c0fe919f35c44e5fb6cb2c434ea361`.

Consequence: a vault asset manager — who may call `signMessage()` but may
NOT set policy (policy is set by the separate core `CORE_ADAPTER_MANAGER`
role) — can obtain a vault signature for a message that violates core-set
policy. If the signed message authorizes a dapp to move vault funds
(permit / Permit2 / swap with `minOut = 0`), that is theft of user funds
via a guard bypass. The PoC proves the policy bypass and the digest
validity; the final fund-movement step depends on the dapp that consumes
the signature.

## Caveats (stated honestly)

- **Conditional on production config.** The finding needs a production
  whitelist directive with a variable-length array followed by a
  constrained trailing field (runtime state, not in the repo). If the team
  confirms such a directive exists, this is Critical by impact.
- **Privileged attacker.** The attacker must hold `VAULT_ASSET_MANAGER`
  on the vault. The finding is about *exceeding* authorized policy, not
  merely holding the role: the guard exists precisely to constrain that
  role, and this bypass removes the constraint for any message shape with
  a variable-length array followed by a constrained field. A triager could
  still invoke the program's "attacks requiring access to privileged
  addresses" exclusion.

## Reproduce

```bash
cd ufarm-finding-02
forge test --match-contract EIP712ArrayShiftPoC -vvvv
```

Expected output: **4 passed, 0 failed**. The bypass test logs the proof:

```
WHITELISTED minOut (EXACT): 1000
SUBMITTED path length: 1
SUBMITTED minOut: 0
GUARD RETURNED DIGEST (non-zero = policy bypass):
0xfee92ac7b18d03354863e22836782e4bc49b3e77697081857b3f8b5d903eae23
EXPECTED VALID EIP-712 DIGEST OF THE VIOLATING MESSAGE:
0xfee92ac7b18d03354863e22836782e4bc49b3e77697081857b3f8b5d903eae23
```

The control test logs `CONTROL full-length minOut=0 rejected (digest == 0):
true`, and the honest test logs the allowed digest
`0x178859b10f7c5d3a5834c2fa988c7bc5da76888ab4b1b93b1b7bd7aab66da9d8`.

## Environment

Standalone Foundry project, no network needed. Tested with forge 1.10.0,
solc 0.8.35 (pinned in foundry.toml).

## Contents

`test/EIP712ArrayShiftPoC.t.sol` plus the production guard it exercises
(`src/adapters/ArbitraryAdapterGuard.sol`, vendored byte-identical —
sha256 `7a4ce244ea857420b5f6956d0ef0789dd4946b31ef06e1946e94cfb719d2d37d` —
with its interfaces, libraries and a minimal `MockCore`), together with
the libraries they need (openzeppelin-contracts-upgradeable,
openzeppelin-contracts, forge-std). All remappings in `remappings.txt`
are relative paths inside this folder. Scope HEAD `b19a651` ("Production
Release 2.1.1").
