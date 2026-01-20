// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @dev Helper library for Anvil custom methods.
library Anvil {
    function anvilSetBalance(Vm vm, address account, uint256 value) internal {
        vm.rpc("anvil_setBalance", string.concat("[\"", vm.toString(account), "\", \"", vm.toString(value), "\"]"));
    }

    function anvilStartImpersonate(Vm vm, address account) internal {
        // Fixes a potential Forge race where the nonce is not fetched in time from the fork for impersonated accounts.
        bytes memory nonceBytes =
            vm.rpc("eth_getTransactionCount", string.concat("[\"", vm.toString(account), "\", \"latest\"]"));
        uint64 nonce = uint64(uint256(bytes32(nonceBytes)) >> (8 * (32 - nonceBytes.length)));
        vm.rpc("anvil_impersonateAccount", string.concat("[\"", vm.toString(account), "\"]"));
        vm.setNonce(account, nonce);
    }
}
