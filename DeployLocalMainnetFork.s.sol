// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MAX_PREMIUM_RATE_BPS} from "../src/Constants.sol";
import {CoveredMetavault} from "../src/CoveredMetavault.sol";
import {Anvil} from "./helpers/Anvil.sol";
import {BaseLocalScript} from "./helpers/BaseLocalScript.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

// USDT.
interface ITetherToken is IERC20 {
    function issue(uint256 amount) external;
    // ...
}

// USDC.
interface IFiatTokenV2_2 is IERC20 {
    function mint(address to, uint256 amount) external;
    // ...
}

// NXM.
interface INXMToken is IERC20 {
    function mint(address account, uint256 amount) external;
    // ...
}

// WETH.
interface WETH9 is IERC20 {
    function deposit() external payable;
    // ...
}

// Nexus Mutual Registry.
interface IRegistry {
    function JOIN_FEE() external view returns (uint256);
    function getContractAddressByIndex(uint256 index) external view returns (address payable);
    function getMemberId(address member) external view returns (uint256);
    function join(address member, bytes memory signature) external payable;
    function setKycAuthAddress(address _kycAuthAddress) external;
    // ...
}

contract DeployLocalMainnetForkScript is BaseLocalScript {
    using Anvil for Vm;

    // Vault keeper from external secure enclave.
    address constant METAVAULT_KEEPER = 0x22E89Ae34dC2572665D5CB050AD31F340Ef67A4d;

    // All addresses below are on Ethereum mainnet.

    // Nexus Mutual.
    IRegistry constant NEXUS_MUTUAL_REGISTRY = IRegistry(0xcafea2c575550512582090AA06d0a069E7236b9e);
    uint256 constant NEXUS_MUTUAL_GOVERNOR_INDEX = 1 << 1;
    uint256 constant NEXUS_MUTUAL_TOKEN_INDEX = 1 << 2;
    uint256 constant NEXUS_MUTUAL_TOKEN_CONTROLLER_INDEX = 1 << 3;

    // Assets and permissioned minters.
    ITetherToken constant USDT = ITetherToken(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address constant USDT_OWNER = 0xC6CDE7C39eB2f0F0095F41570af89eFC2C1Ea828;

    IFiatTokenV2_2 constant USDC = IFiatTokenV2_2(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDC_MINTER = 0x5B6122C109B78C6755486966148C1D70a50A47D7; // Permissioned to mint USDC

    WETH9 constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Vault addresses for different underlying assets.
    IERC4626 constant SMOKEHOUSE_USDC = IERC4626(0xBEeFFF209270748ddd194831b3fa287a5386f5bC); // bbqUSDC
    IERC4626 constant SMOKEHOUSE_USDT = IERC4626(0xA0804346780b4c2e3bE118ac957D1DB82F9d7484); // bbqUSDT
    IERC4626 constant INDEX_COOP_HYETH = IERC4626(0x701907283a57FF77E255C3f1aAD790466B8CE4ef); // mhyETH

    IERC4626 constant HYPER_USDC_MIDCURVE = IERC4626(0xCdaea3dde6cE5969aA1414A82A3A681cEd51Ce72); // hyperUSDCm
    IERC4626 constant SINGULARV_ETH = IERC4626(0x739d8a60ED4b14E4cB6DCAEAF79d2ec0Ca092237); // svETH
    IERC4626 constant CLEARSTAR_USDC_REACTOR = IERC4626(0x62fE596d59fB077c2Df736dF212E0AFfb522dC78); // CSUSDC

    // Initial balances.
    uint256 constant USDT_BALANCE = 1_500_001e6; // $1.5M + $1 to make sure truncated numbers are round during demo.
    uint256 constant USDT_MORPHO_DEPOSIT = 1_500_001e6; // $1.5M deposited to Morpho Smokehouse USDT.

    uint256 constant USDC_BALANCE = 2_500_000e6; // $2.5M
    uint256 constant USDC_MORPHO_DEPOSIT = 1_200_000e6; // $1.2M deposited to Morpho Smokehouse USDC.
    uint256 constant USDC_MORPHO_DEPOSIT_USER2 = 491_337e6; // $491,337 deposited by User 2.

    uint256 constant WETH_BALANCE = 314 ether;

    // Minimum request assets.
    uint96 constant MINIMUM_REQUEST_ASSETS_USDC = 10e6; // $10
    uint96 constant MINIMUM_REQUEST_ASSETS_USDT = 10e6; // $10
    uint96 constant MINIMUM_REQUEST_ASSETS_WETH = 3e15; // ~$10

    // Covered vault instances.
    CoveredMetavault metavaultUsdc;
    CoveredMetavault metavaultUsdt;
    CoveredMetavault metavaultEth;
    CoveredMetavault metavaultHyperMidcurveUsdc;
    CoveredMetavault metavaultSingularvEth;
    CoveredMetavault metavaultClearstarUsdc;

    function _nexusMutualMintNXM(address to, uint256 amount) internal returns (uint256 balance) {
        address tokenController = NEXUS_MUTUAL_REGISTRY.getContractAddressByIndex(NEXUS_MUTUAL_TOKEN_CONTROLLER_INDEX);
        INXMToken token = INXMToken(NEXUS_MUTUAL_REGISTRY.getContractAddressByIndex(NEXUS_MUTUAL_TOKEN_INDEX));

        vm.anvilStartImpersonate(tokenController);
        vm.anvilSetBalance(tokenController, uint256(1 ether)); // Pays for gas.

        vm.broadcast(tokenController);
        token.mint(to, amount);

        return token.balanceOf(to);
    }

    function _nexusMutualAddMember(address member, Signer memory signer) internal returns (uint256 memberId) {
        memberId = NEXUS_MUTUAL_REGISTRY.getMemberId(member);

        if (memberId > 0) return memberId;

        // Could also be done via the new `anvil_impersonateSignature` which is not yet stable (as of Sep 22, 2025).
        /*
        vm.rpc(
            "anvil_impersonateSignature",
            string.concat(
              '[["', vm.toString(signature), '","', vm.toString(NEXUS_MUTUAL_MEMBERSHIP_COORDINATOR), '"]]'
            )
        );
        */

        address governor = NEXUS_MUTUAL_REGISTRY.getContractAddressByIndex(NEXUS_MUTUAL_GOVERNOR_INDEX);

        // Step 1) Set the signer as the KYC auth address signing for membership.
        vm.anvilStartImpersonate(governor);
        vm.anvilSetBalance(governor, uint256(1 ether)); // Pays for gas.
        vm.broadcast(governor);
        NEXUS_MUTUAL_REGISTRY.setKycAuthAddress(signer.addr);

        // Step 2) Sign membership approval using signer's private key.
        bytes32 JOIN_TYPEHASH = keccak256("Join(address member)");
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NexusMutualRegistry"),
                keccak256("1.0.0"),
                uint256(1), // Ethereum mainnet as we're forking.
                address(NEXUS_MUTUAL_REGISTRY)
            )
        );

        bytes32 messageHash = keccak256(abi.encode(JOIN_TYPEHASH, member));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, messageHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Step 3) Join as a Nexus Mutual member.
        uint256 joiningFee = NEXUS_MUTUAL_REGISTRY.JOIN_FEE();
        vm.broadcast(signer.privateKey);
        NEXUS_MUTUAL_REGISTRY.join{value: joiningFee}(member, signature);

        memberId = NEXUS_MUTUAL_REGISTRY.getMemberId(member);
    }

    function _metavaultDeploy(IERC4626 underlyingAsset, uint96 minimumRequestAssets)
        internal
        returns (CoveredMetavault)
    {
        string memory vaultSymbol = string.concat("OC-", underlyingAsset.symbol());
        string memory vaultName = string.concat("Covered ", underlyingAsset.name());

        // Deploy vault proxy and implementation
        address implementation = address(new CoveredMetavault());
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(
                CoveredMetavault.initialize,
                (
                    underlyingAsset,
                    vaultName,
                    vaultSymbol,
                    minimumRequestAssets,
                    deployer.addr,
                    MAX_PREMIUM_RATE_BPS,
                    1000
                )
            )
        );

        return CoveredMetavault(proxy);
    }

    function _metavaultConfigure(CoveredMetavault vault) internal {
        // Assign roles: [Deployer] is Owner, Manager, Keeper and Guardian.
        //               [Metavault keeper] is Keeper.
        vault.grantRole(vault.MANAGER_ROLE(), deployer.addr);
        vault.grantRole(vault.KEEPER_ROLE(), deployer.addr);
        vault.grantRole(vault.GUARDIAN_ROLE(), deployer.addr);
        vault.grantRole(vault.KEEPER_ROLE(), METAVAULT_KEEPER);
    }

    function prepareAssets() public {
        // =====================================================================
        // USDT & Morpho Smokehouse USDT
        // =====================================================================

        // Mint USDT to User 1.
        vm.anvilStartImpersonate(USDT_OWNER);
        vm.anvilSetBalance(USDT_OWNER, 1 ether);
        vm.startBroadcast(USDT_OWNER);
        USDT.issue(USDT_BALANCE);
        SafeERC20.safeTransfer(USDT, user1.addr, USDT_BALANCE);
        vm.stopBroadcast();

        // User 1 deposits USDT into Morpho Smokehouse USDT Morpho vault.
        vm.startBroadcast(user1.privateKey);
        SafeERC20.forceApprove(USDT, address(SMOKEHOUSE_USDT), USDT_MORPHO_DEPOSIT);
        SMOKEHOUSE_USDT.deposit(USDT_MORPHO_DEPOSIT, user1.addr);
        vm.stopBroadcast();

        // =====================================================================
        // USDC & Smokehouse USDC
        // =====================================================================

        // Mint USDC to User 1 and User 2.
        vm.anvilStartImpersonate(USDC_MINTER);
        vm.startBroadcast(USDC_MINTER);
        USDC.mint(user1.addr, USDC_BALANCE);
        USDC.mint(user2.addr, USDC_BALANCE);
        USDC.mint(METAVAULT_KEEPER, USDC_BALANCE);
        vm.stopBroadcast();

        // Deposit USDC to Smokehouse USDC vault.
        vm.startBroadcast(user1.privateKey);
        USDC.approve(address(SMOKEHOUSE_USDC), USDC_MORPHO_DEPOSIT);
        SMOKEHOUSE_USDC.deposit(USDC_MORPHO_DEPOSIT, user1.addr);
        vm.stopBroadcast();

        // User 2 deposits USDC to Smokehouse USDC vault.
        vm.startBroadcast(user2.privateKey);
        USDC.approve(address(SMOKEHOUSE_USDC), USDC_MORPHO_DEPOSIT_USER2);
        SMOKEHOUSE_USDC.deposit(USDC_MORPHO_DEPOSIT_USER2, user2.addr);
        vm.stopBroadcast();

        // =====================================================================
        // WETH
        // =====================================================================

        // No deposit to the Morpho vault, only wrap ETH.
        vm.broadcast(user1.privateKey);
        WETH.deposit{value: WETH_BALANCE}();
    }

    function setupMetavaults() public {
        // Fund metavault keeper.
        vm.anvilSetBalance(METAVAULT_KEEPER, 1_000_000 ether);

        // Make the metavault keeper a Nexus Mutual member.
        uint256 memberId = _nexusMutualAddMember(METAVAULT_KEEPER, deployer);
        uint256 nxmBalance = _nexusMutualMintNXM(METAVAULT_KEEPER, 10_000e18);
        // Deploy and configure all three metavaults.
        vm.startBroadcast(deployer.privateKey);
        metavaultUsdc = _metavaultDeploy(SMOKEHOUSE_USDC, MINIMUM_REQUEST_ASSETS_USDC);
        metavaultUsdt = _metavaultDeploy(SMOKEHOUSE_USDT, MINIMUM_REQUEST_ASSETS_USDT);
        metavaultEth = _metavaultDeploy(INDEX_COOP_HYETH, MINIMUM_REQUEST_ASSETS_WETH);
        metavaultHyperMidcurveUsdc = _metavaultDeploy(HYPER_USDC_MIDCURVE, MINIMUM_REQUEST_ASSETS_USDC);
        metavaultSingularvEth = _metavaultDeploy(SINGULARV_ETH, MINIMUM_REQUEST_ASSETS_WETH);
        metavaultClearstarUsdc = _metavaultDeploy(CLEARSTAR_USDC_REACTOR, MINIMUM_REQUEST_ASSETS_USDC);

        _metavaultConfigure(metavaultUsdc);
        _metavaultConfigure(metavaultUsdt);
        _metavaultConfigure(metavaultEth);
        _metavaultConfigure(metavaultHyperMidcurveUsdc);
        _metavaultConfigure(metavaultSingularvEth);
        _metavaultConfigure(metavaultClearstarUsdc);
        vm.stopBroadcast();

        // =====================================================================
        // Covered Morpho Smokehouse USDT metavault
        // =====================================================================

        // User 1 requests deposit of Morpho Smokehouse USDT shares into the metavault.
        vm.startBroadcast(user1.privateKey);
        uint256 bbqUsdtShares = SMOKEHOUSE_USDT.balanceOf(user1.addr);
        SMOKEHOUSE_USDT.approve(address(metavaultUsdt), bbqUsdtShares);
        metavaultUsdt.requestDeposit(bbqUsdtShares, user1.addr, user1.addr);
        vm.stopBroadcast();

        // User 2 requests deposit of Smokehouse USDC shares into the metavault.
        vm.startBroadcast(user2.privateKey);
        uint256 bbqUsdcShares = SMOKEHOUSE_USDC.balanceOf(user2.addr);
        SMOKEHOUSE_USDC.approve(address(metavaultUsdc), bbqUsdcShares);
        metavaultUsdc.requestDeposit(bbqUsdcShares, user2.addr, user2.addr);
        vm.stopBroadcast();

        // Settle the metavault.
        vm.broadcast(deployer.privateKey);
        metavaultUsdt.settle(0, new uint256[](0));

        // Claim the shares from the metavault.
        vm.broadcast(user1.privateKey);
        metavaultUsdt.deposit(bbqUsdtShares, user1.addr, user1.addr);

        // =====================================================================
        // Covered Smokehouse USDC metavault
        // =====================================================================

        // Settle the metavault for user 2's deposit request.
        vm.broadcast(deployer.privateKey);
        metavaultUsdc.settle(0, new uint256[](0));

        // User 2 claims the shares from the metavault.
        vm.broadcast(user2.privateKey);
        metavaultUsdc.deposit(bbqUsdcShares, user2.addr, user2.addr);

        // =====================================================================
        // Covered Index Coop hyETH metavault
        // =====================================================================

        // No operations.

        // =====================================================================

        // Log deployment information.
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("USDC metavault deployed at:", address(metavaultUsdc));
        console.log("USDT metavault deployed at:", address(metavaultUsdt));
        console.log("WETH metavault deployed at:", address(metavaultEth));
        console.log("hyperUSDCm metavault deployed at:", address(metavaultHyperMidcurveUsdc));
        console.log("svETH metavault deployed at:", address(metavaultSingularvEth));
        console.log("CSUSDC metavault deployed at:", address(metavaultClearstarUsdc));
        console.log("Deployer:", deployer.addr);
        console.log("User 1:", user1.addr);
        console.log("User 2:", user2.addr);
        console.log("Metavault Keeper:", METAVAULT_KEEPER);
        console.log("Keeper Nexus Mutual member ID:", memberId);
        console.log("Keeper NXM balance:", nxmBalance);

        // Log final balances.
        console.log("=== FINAL BALANCES ===");
        console.log("User 1 USDT balance:", USDT.balanceOf(user1.addr));
        console.log("User 1 USDC balance:", USDC.balanceOf(user1.addr));
        console.log("User 2 USDC balance:", USDC.balanceOf(user2.addr));
        console.log("User 1 WETH balance:", WETH.balanceOf(user1.addr));

        console.log("User 1 bbqUSDT shares:", SMOKEHOUSE_USDT.balanceOf(user1.addr));
        console.log("User 1 bbqUSDC shares:", SMOKEHOUSE_USDC.balanceOf(user1.addr));
        console.log("User 2 bbqUSDC shares:", SMOKEHOUSE_USDC.balanceOf(user2.addr));
        console.log("User 1 hyETH shares:", INDEX_COOP_HYETH.balanceOf(user1.addr));

        console.log("User 1 OC-bbqUSDT shares:", metavaultUsdt.balanceOf(user1.addr));
        console.log("User 2 OC-bbqUSDC shares:", metavaultUsdc.balanceOf(user2.addr));
    }
}
