// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";

import {ICoveredMetavaultV2} from "test/mocks/MockCoveredMetavaultV2.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract AccessRolesTest is CoveredMetavaultTestBase {
    function test_SetPremiumCollector_OnlyManager() public {
        address newCollector = makeAddr("newCollector");
        bytes32 managerRole = vault.MANAGER_ROLE();

        // Keeper cannot call.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, managerRole)
        );
        vault.setPremiumCollector(newCollector);

        // Users cannot call.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, managerRole)
        );
        vault.setPremiumCollector(newCollector);

        // Manager can call.
        vm.prank(manager);
        vault.setPremiumCollector(newCollector);
    }

    function test_SetPremiumRateBps_OnlyManager() public {
        uint16 rateBps = 1000;
        bytes32 managerRole = vault.MANAGER_ROLE();

        // Users cannot call.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, managerRole)
        );
        vault.setPremiumRateBps(rateBps);

        // Keeper cannot call.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, managerRole)
        );
        vault.setPremiumRateBps(rateBps);

        // Manager can call.
        vm.prank(manager);
        vault.setPremiumRateBps(rateBps);
    }

    function test_SettleDeposits_OnlyKeeper() public {
        bytes32 keeperRole = vault.KEEPER_ROLE();

        // Users cannot call.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, keeperRole)
        );
        vault.settle(0, new uint256[](0));

        // Keeper can call.
        vm.prank(keeper);
        vault.settle(0, new uint256[](0));
    }

    function test_GrantRevokeRoles_AdminOnly() public {
        bytes32 ownerRole = vault.OWNER_ROLE();
        bytes32 managerRole = vault.MANAGER_ROLE();

        // Users cannot grant.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ownerRole)
        );
        vault.grantRole(managerRole, other);

        // Manager cannot grant.
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, ownerRole)
        );
        vault.grantRole(managerRole, manager);

        // Keeper cannot grant.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, ownerRole)
        );
        vault.grantRole(managerRole, keeper);

        // Owner can grant and revoke.
        vm.startPrank(vaultOwner);
        vault.grantRole(managerRole, other);
        assertTrue(vault.hasRole(managerRole, other));
        vault.revokeRole(managerRole, other);
        assertFalse(vault.hasRole(managerRole, other));
        vm.stopPrank();
    }

    function test_Upgrade_OnlyOwner() public {
        bytes32 ownerRole = vault.OWNER_ROLE();

        // Deploy new implementation.
        Options memory opts;
        address impl = Upgrades.prepareUpgrade("MockCoveredMetavaultV2.sol:MockCoveredMetavaultV2", opts);

        // Keeper cannot upgrade.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, ownerRole)
        );
        IUUPSUpgradeable(address(vault)).upgradeToAndCall(impl, "");

        // Manager cannot upgrade.
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, ownerRole)
        );
        IUUPSUpgradeable(address(vault)).upgradeToAndCall(impl, "");

        // Users cannot upgrade.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ownerRole)
        );
        IUUPSUpgradeable(address(vault)).upgradeToAndCall(impl, "");

        // Owner can upgrade.
        vm.prank(vaultOwner);
        IUUPSUpgradeable(address(vault)).upgradeToAndCall(impl, "");

        // Verify new implementation is active.
        uint256 v = ICoveredMetavaultV2(address(vault)).version();
        assertEq(v, 2);
    }

    function test_TransferOwnership_OnlyOwner() public {
        address newOwner = makeAddr("newOwner");
        bytes32 ownerRole = vault.OWNER_ROLE();

        // Keeper cannot initiate transfer.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, ownerRole)
        );
        vault.transferOwnership(newOwner);

        // Manager cannot initiate transfer.
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, ownerRole)
        );
        vault.transferOwnership(newOwner);

        // Users cannot initiate transfer.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, ownerRole)
        );
        vault.transferOwnership(newOwner);

        // Guardian cannot initiate transfer.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, ownerRole)
        );
        vault.transferOwnership(newOwner);

        // Verify current owner before transfer.
        assertTrue(vault.hasRole(ownerRole, vaultOwner));
        assertFalse(vault.hasRole(ownerRole, newOwner));

        // Owner can initiate transfer.
        vm.expectEmit(true, true, false, true);
        emit ICoveredMetavault.OwnershipTransferStarted(vaultOwner, newOwner);
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);

        // Ownership not yet transferred (pending acceptance).
        assertTrue(vault.hasRole(ownerRole, vaultOwner));
        assertFalse(vault.hasRole(ownerRole, newOwner));

        // New owner accepts ownership.
        vm.expectEmit(true, true, false, true);
        emit ICoveredMetavault.OwnershipTransferred(vaultOwner, newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        // Verify ownership has been transferred.
        assertFalse(vault.hasRole(ownerRole, vaultOwner));
        assertTrue(vault.hasRole(ownerRole, newOwner));
    }

    function test_TransferOwnership_RevertWhen_ZeroAddress() public {
        vm.prank(vaultOwner);
        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertWhen_NotPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        // Initiate transfer.
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);

        // Random user cannot accept.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidPendingOwner.selector, other));
        vault.acceptOwnership();

        // Current owner cannot accept.
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidPendingOwner.selector, vaultOwner));
        vault.acceptOwnership();
    }

    function test_TransferOwnership_NewOwnerCanUseRole() public {
        address newOwner = makeAddr("newOwner");
        bytes32 ownerRole = vault.OWNER_ROLE();
        bytes32 managerRole = vault.MANAGER_ROLE();

        // Initiate and complete ownership transfer.
        vm.prank(vaultOwner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        // New owner can perform owner-only operations.
        vm.prank(newOwner);
        vault.grantRole(managerRole, other);
        assertTrue(vault.hasRole(managerRole, other));

        // Old owner cannot perform owner-only operations.
        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, vaultOwner, ownerRole)
        );
        vault.revokeRole(managerRole, other);
    }

    function test_RenounceRole_RevertWhen_OwnerRole() public {
        bytes32 ownerRole = vault.OWNER_ROLE();

        // Verify owner has the role.
        assertTrue(vault.hasRole(ownerRole, vaultOwner));

        // Owner cannot renounce OWNER_ROLE (would brick the contract).
        vm.prank(vaultOwner);
        vm.expectRevert();
        vault.renounceRole(ownerRole, vaultOwner);

        // Verify owner still has the role.
        assertTrue(vault.hasRole(ownerRole, vaultOwner));
    }

    function test_RenounceRole_AllowedForOtherRoles() public {
        bytes32 managerRole = vault.MANAGER_ROLE();

        // Verify manager has the role.
        assertTrue(vault.hasRole(managerRole, manager));

        // Manager can renounce MANAGER_ROLE.
        vm.prank(manager);
        vault.renounceRole(managerRole, manager);

        // Verify manager no longer has the role.
        assertFalse(vault.hasRole(managerRole, manager));
    }
}
