// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title RedemptionsIntegrationTest
/// @notice Integration flows mixing premium streaming, deposits, and redemptions.
contract RedemptionsIntegrationTest is CoveredMetavaultTestBase {
    function test_DonationAttack_NonProfitable() public {
        // Attacker strategy:
        //   1) Mint minimal shares.
        //   2) Donate a large amount directly to the vault to inflate price per share.
        //   3) Victim deposits, receiving fewer shares due to inflated price.
        //   4) Attacker redeems their shares, extracting victim's donation.
        // Mitigation: Donations bypass tracked assets, so attacker cannot profit.

        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        uint256 attackerInitialDeposit = 1;
        uint256 attackerDonation = 20_000e18;
        uint256 victimDeposit = 20_000e18;

        // Fund and approve both parties.
        _mintAndApprove(attacker, attackerInitialDeposit);
        _mintAndApprove(victim, victimDeposit);

        // Step 1: Attacker mints minimal shares (1 unit, initial 1:1).
        vm.prank(attacker);
        vault.requestDeposit(attackerInitialDeposit, attacker, attacker);
        _settle();
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(attackerInitialDeposit, attacker, attacker);
        assertEq(attackerShares, attackerInitialDeposit);

        // Step 2: Attacker donates a large amount to inflate price per share.
        underlyingAsset.mint(attacker, attackerDonation);
        vm.startPrank(attacker);
        underlyingAsset.approve(address(asset), attackerDonation);
        asset.deposit(attackerDonation, attacker);
        assertTrue(asset.transfer(address(vault), attackerDonation));
        vm.stopPrank();

        // Step 3: Victim deposits after price is inflated.
        vm.prank(victim);
        vault.requestDeposit(victimDeposit, victim, victim);
        _settle();
        uint256 victimClaimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, victim);
        assertEq(victimClaimable, victimDeposit);
        vm.prank(victim);
        vault.deposit(victimClaimable, victim, victim);

        // Step 4: Attacker redeems their minimal shares via async redemption flow.
        vm.prank(attacker);
        uint256 redeemRequestId = vault.requestRedeem(attackerShares, attacker, attacker);
        _settle(0, redeemRequestId);
        vm.prank(attacker);
        uint256 assetsOut = vault.redeem(attackerShares, attacker, attacker);

        // Redemption must not result in more than donation + initial deposit.
        assertLt(assetsOut, attackerDonation + attackerInitialDeposit);
    }

    function test_DonationGriefingAttack_Mitigated() public {
        // Attacker strategy:
        //   1) Victim requests a deposit on an empty vault.
        //   2) Attacker front-runs settlement by donating directly to the vault.
        //   3) Settlement calculates shares using inflated totalAssets.
        //   4) Victim receives 0 shares, funds are locked.
        // Mitigation: Donations bypass tracked assets, so totalAssets is unaffected.

        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        uint256 victimDeposit = 1000e18;
        uint256 attackerDonation = victimDeposit + 1;

        _mintAndApprove(victim, victimDeposit);

        underlyingAsset.mint(attacker, attackerDonation);
        vm.startPrank(attacker);
        underlyingAsset.approve(address(asset), attackerDonation);
        asset.deposit(attackerDonation, attacker);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);

        vm.prank(victim);
        vault.requestDeposit(victimDeposit, victim, victim);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, victim), victimDeposit);
        assertEq(vault.totalPendingAssets(), victimDeposit);
        assertEq(vault.totalAssets(), 0);

        vm.prank(attacker);
        asset.transfer(address(vault), attackerDonation);

        assertEq(vault.totalAssets(), 0);

        _settle();

        uint256 claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, victim);
        assertEq(claimable, victimDeposit);

        vm.prank(victim);
        uint256 shares = vault.deposit(victimDeposit, victim, victim);

        assertEq(shares, victimDeposit);
        assertEq(vault.balanceOf(victim), victimDeposit);
        assertEq(vault.totalSupply(), victimDeposit);
        assertEq(vault.totalAssets(), victimDeposit);

        uint256 actualBalance = asset.balanceOf(address(vault));
        assertEq(actualBalance, victimDeposit + attackerDonation);
    }
}
