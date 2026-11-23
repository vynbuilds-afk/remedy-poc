// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

/// @notice Minimal mock of IUFarmPermissions: every permission query returns true.
/// Only used so the standalone PoC can deploy ArbitraryAdapterGuard (which
/// requires a non-empty core address and checks CORE_ADAPTER_MANAGER).
contract MockCore {
    function setPermissionMask(address, uint256) external {}

    function permissionMask(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function accountHasPermission(address, uint256) external pure returns (bool) {
        return true;
    }

    function accountHasAnyPermission(address, uint256) external pure returns (bool) {
        return true;
    }
}
