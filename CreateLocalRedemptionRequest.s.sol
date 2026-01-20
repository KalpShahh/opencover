// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICoveredMetavault} from "../src/interfaces/ICoveredMetavault.sol";
import {BaseLocalScript} from "./helpers/BaseLocalScript.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {console} from "forge-std/Script.sol";

contract CreateRedemptionRequestScript is BaseLocalScript {
    uint256 constant REDEEM_AMOUNT_IN_SHARES = 100e18;

    Signer user;

    function setUp() public override {
        super.setUp();
        user = user2;
    }

    function run() public {
        ICoveredMetavault vault = ICoveredMetavault(vm.envAddress("VAULT_ADDRESS"));
        string memory vaultSymbol = vault.symbol();

        IERC4626 asset = IERC4626(vault.asset());
        string memory assetSymbol = asset.symbol();

        // First, check and claim any claimable deposits to maximise user's shares.
        uint256 claimableAssets = vault.maxDeposit(user.addr);
        console.log("User claimable deposit assets:", claimableAssets, assetSymbol);

        if (claimableAssets > 0) {
            vm.broadcast(user.privateKey);
            uint256 claimedShares = vault.deposit(claimableAssets, user.addr, user.addr);
            console.log("Claimed shares from deposits:", claimedShares, vaultSymbol);
        }

        // Check if user has sufficient shares for redemption.
        uint256 userShares = vault.balanceOf(user.addr);
        console.log("User current shares:", userShares, vaultSymbol);
        if (userShares < REDEEM_AMOUNT_IN_SHARES) {
            console.log("ERROR: User doesn't have enough shares for redemption.");
            console.log("Required shares:", REDEEM_AMOUNT_IN_SHARES, vaultSymbol);
            console.log("Available shares:", userShares, vaultSymbol);
            return;
        }

        vm.startBroadcast(user.privateKey);
        vault.approve(address(vault), REDEEM_AMOUNT_IN_SHARES);
        uint256 requestId = vault.requestRedeem(REDEEM_AMOUNT_IN_SHARES, user.addr, user.addr);
        vm.stopBroadcast();

        // Print the request ID and related info to the console.
        console.log("=== REDEMPTION REQUEST CREATED ===");
        console.log("Request ID:", requestId);
        console.log("Shares requested for redemption:", REDEEM_AMOUNT_IN_SHARES, vaultSymbol);
        console.log("User remaining shares:", vault.balanceOf(user.addr), vaultSymbol);
        console.log("User pending redemption request:", vault.pendingRedeemRequest(requestId, user.addr), vaultSymbol);
    }
}
