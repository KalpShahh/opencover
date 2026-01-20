// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICoveredMetavault} from "../src/interfaces/ICoveredMetavault.sol";
import {BaseLocalScript} from "./helpers/BaseLocalScript.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {console} from "forge-std/Script.sol";

contract CreateDepositRequestScript is BaseLocalScript {
    uint256 constant DEPOSIT_AMOUNT_IN_UNDERLYING = 1000e6; // 1000 USDC

    Signer user;

    function setUp() public override {
        super.setUp();
        user = user2;
    }

    function run() public {
        ICoveredMetavault vault = ICoveredMetavault(vm.envAddress("VAULT_ADDRESS"));

        // Get asset from vault.
        IERC4626 asset = IERC4626(vault.asset());
        string memory assetSymbol = asset.symbol();

        uint256 depositAmountInAsset = asset.convertToShares(DEPOSIT_AMOUNT_IN_UNDERLYING);

        // Check user's current balance.
        uint256 userAssetBalance = asset.balanceOf(user.addr);
        console.log("User current asset balance:", userAssetBalance, assetSymbol);
        if (userAssetBalance < depositAmountInAsset) {
            console.log("ERROR: User doesn't have enough assets for deposit request.");
            console.log("Required assets:", depositAmountInAsset, assetSymbol);
            console.log("Available assets:", userAssetBalance, assetSymbol);
            return;
        }

        vm.startBroadcast(user.privateKey);
        asset.approve(address(vault), depositAmountInAsset);
        vault.requestDeposit(depositAmountInAsset, user.addr, user.addr);
        vm.stopBroadcast();

        // Print the deposit request details to the console.
        console.log("=== DEPOSIT REQUEST CREATED ===");
        console.log("Assets requested for deposit:", depositAmountInAsset, assetSymbol);
        console.log("User remaining asset balance:", asset.balanceOf(user.addr), assetSymbol);
        console.log("User pending deposit request:", vault.pendingDepositRequest(0, user.addr), assetSymbol);
        console.log("Vault total pending deposits:", vault.totalPendingAssets(), assetSymbol);
    }
}
