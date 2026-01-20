// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MAX_PREMIUM_RATE_BPS} from "../src/Constants.sol";
import {CoveredMetavault} from "../src/CoveredMetavault.sol";
import {Anvil} from "./helpers/Anvil.sol";
import {BaseLocalScript} from "./helpers/BaseLocalScript.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockERC4626} from "./helpers/MockERC4626.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

contract DeployLocalDevScript is BaseLocalScript {
    using Anvil for Vm;

    // Test vault keeper (external secure enclave).
    address constant TEST_METAVAULT_KEEPER = 0x62F5794eFb8644618646e01b3D383df036Fc6613;

    // Initial balance in assets for each test user.
    uint256 constant INITIAL_ASSET_BALANCE = 1000e18;

    MockERC20 underlying;
    MockERC4626 asset;
    CoveredMetavault vault;

    function run() public {
        vm.startBroadcast(deployer.privateKey);

        // Deploy test asset (ERC-4626 wrapping a mock ERC-20 underlying).
        underlying = new MockERC20("Mock USDC", "mUSDC");
        asset = new MockERC4626(underlying, "Mock Yield USDC", "myUSDC");

        // Deploy vault proxy and implementation.
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (asset, "Covered Metavault", "cmUSDC", 0, deployer.addr, MAX_PREMIUM_RATE_BPS, 1000)
            )
        );
        vault = CoveredMetavault(proxy);

        // Fund vault keeper.
        vm.anvilSetBalance(TEST_METAVAULT_KEEPER, 1_000_000 ether);

        // Test deployer (owner) is Manager and Keeper too.
        vault.grantRole(vault.MANAGER_ROLE(), deployer.addr);
        vault.grantRole(vault.KEEPER_ROLE(), deployer.addr);

        vault.grantRole(vault.KEEPER_ROLE(), TEST_METAVAULT_KEEPER);

        // Mint assets to test users.
        underlying.mint(user1.addr, INITIAL_ASSET_BALANCE);
        underlying.mint(user2.addr, INITIAL_ASSET_BALANCE);
        vm.stopBroadcast();

        // Seed vault shares to test users via ERC-4626 deposits.
        vm.startBroadcast(user1.privateKey);
        underlying.approve(address(asset), INITIAL_ASSET_BALANCE);
        asset.deposit(INITIAL_ASSET_BALANCE, user1.addr);
        vm.stopBroadcast();

        vm.startBroadcast(user2.privateKey);
        underlying.approve(address(asset), INITIAL_ASSET_BALANCE);
        asset.deposit(INITIAL_ASSET_BALANCE, user2.addr);
        vm.stopBroadcast();

        console.log("Asset deployed at:", address(asset));
        console.log("Vault deployed at:", address(vault));
        console.log("Deployer:", deployer.addr);
        console.log("User 1:", user1.addr);
        console.log("User 2:", user2.addr);

        // Epoch 0: U1 requests 500.
        vm.startBroadcast(user1.privateKey);
        asset.approve(address(vault), 500e18);
        vault.requestDeposit(500e18, user1.addr, user1.addr);
        vm.stopBroadcast();

        vm.broadcast(deployer.privateKey);
        vault.settle(0, new uint256[](0));

        // Epoch 1: U1 claims 500, U1 requests 500, U2 requests 1000.
        vm.startBroadcast(user1.privateKey);
        vault.deposit(250e18, user1.addr, user1.addr);
        asset.approve(address(vault), 500e18);
        vault.requestDeposit(500e18, user1.addr, user1.addr);
        vm.stopBroadcast();

        vm.startBroadcast(user2.privateKey);
        asset.approve(address(vault), 1000e18);
        vault.requestDeposit(1000e18, user2.addr, user2.addr);
        vm.stopBroadcast();

        // State:
        //   U1: pending 500, 250 claimable, 250 claimed
        //   U2: pending 1000
    }
}
