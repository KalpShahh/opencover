// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICoveredMetavault} from "../src/interfaces/ICoveredMetavault.sol";
import {BaseLocalScript} from "./helpers/BaseLocalScript.sol";

import {console} from "forge-std/Script.sol";

contract SettleLocalRequestsScript is BaseLocalScript {
    function run() public {
        ICoveredMetavault vault = ICoveredMetavault(vm.envAddress("VAULT_ADDRESS"));

        // Get pending assets before settlement.
        uint256 pendingAssets = vault.totalPendingAssets();
        console.log("Pending assets before settlement:", pendingAssets);

        // Parse redemption request IDs from environment variable.
        // Format: comma-separated list like "1,2,3" or empty string for no redemptions.
        uint256[] memory redeemRequestIds;
        string memory redeemIdsStr = vm.envOr("REDEEM_REQUEST_IDS", string(""));

        if (bytes(redeemIdsStr).length > 0) {
            // Split the comma-separated string into individual request IDs.
            string[] memory idStrings = vm.split(redeemIdsStr, ",");
            redeemRequestIds = new uint256[](idStrings.length);

            console.log("Redemption request IDs to settle:");
            for (uint256 i = 0; i < idStrings.length; i++) {
                redeemRequestIds[i] = vm.parseUint(idStrings[i]);
                console.log("  -", redeemRequestIds[i]);
            }
        } else {
            console.log("No redemption request IDs provided, settling deposits only");
            redeemRequestIds = new uint256[](0);
        }

        // Settle all pending deposits and the specified redemption requests.
        // Using 0 for expectedPendingAssets means "settle all pending deposits".
        vm.broadcast(deployer.privateKey);
        vault.settle(0, redeemRequestIds);

        // Show results.
        console.log("=== SETTLEMENT COMPLETE ===");
        console.log("Pending assets after settlement:", vault.totalPendingAssets());

        if (redeemRequestIds.length > 0) console.log("Settled redemption requests:", redeemRequestIds.length);
    }
}
