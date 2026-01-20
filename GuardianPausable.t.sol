// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract GuardianPausableTest is CoveredMetavaultTestBase {
    function test_Pause_Unpause_OnlyGuardian() public {
        bytes32 guardianRole = vault.GUARDIAN_ROLE();

        // Non-guardian cannot pause.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, guardianRole)
        );
        vault.pause();

        // Guardian can pause.
        vm.prank(guardian);
        vault.pause();
        assertTrue(PausableUpgradeable(address(vault)).paused());

        // Non-guardian cannot unpause.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, guardianRole)
        );
        vault.unpause();

        // Guardian can unpause.
        vm.prank(guardian);
        vault.unpause();
        assertFalse(PausableUpgradeable(address(vault)).paused());
    }

    function test_Paused_BlocksStateChangingOperations() public {
        // Prepare a pending deposit.
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Pause the vault.
        vm.prank(guardian);
        vault.pause();

        // requestDeposit reverts when paused.
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // ERC-7540 deposit path reverts when paused.
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(1, owner, owner);

        // ERC-7540 mint path reverts when paused.
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.mint(1, owner, owner);

        // ERC-4626 convenience deposit/mint also revert when paused.
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.deposit(1, receiver);

        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.mint(1, receiver);

        // settle reverts when paused (keeper-only).
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _settle();
    }
}
