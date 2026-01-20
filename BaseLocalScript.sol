// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

abstract contract BaseLocalScript is Script {
    struct Signer {
        address addr;
        uint256 privateKey;
    }

    // Number of signers, including the deployer.
    uint8 constant NUM_SIGNERS = 3;

    mapping(uint8 => Signer) signers;
    Signer deployer;
    Signer user1;
    Signer user2;

    function setUp() public virtual {
        string memory mnemonic = vm.envString("ANVIL_MNEMONIC");
        for (uint8 i = 0; i < NUM_SIGNERS + 1; i++) {
            uint256 privateKey = vm.deriveKey(mnemonic, i);
            signers[i] = Signer({addr: vm.addr(privateKey), privateKey: privateKey});
        }

        // Convenience aliases for signers.
        deployer = signers[0];
        user1 = signers[1];
        user2 = signers[2];
    }
}
