// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavault} from "src/CoveredMetavault.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Config} from "forge-std/Config.sol";
import {LibVariable, TypeKind, Variable} from "forge-std/LibVariable.sol";
import {Script, console} from "forge-std/Script.sol";

abstract contract VaultConfigLoader is Config {
    using LibVariable for Variable;

    struct VaultConfig {
        IERC4626 wrappedVault;
        address premiumCollector;
        address owner;
        address guardian;
        address manager;
        address keeper;
        uint16 premiumRateBps;
        uint16 maxPremiumRateBps;
        uint96 minimumRequestAssets;
    }

    function _readConfig() internal view returns (VaultConfig memory vaultConfig) {
        vaultConfig.wrappedVault = IERC4626(config.get("wrapped_vault").toAddress());

        uint256 minRequestAssets = config.get("minimum_request_assets").toUint256();
        require(minRequestAssets <= type(uint96).max, "minimum_request_assets too large");
        vaultConfig.minimumRequestAssets = uint96(minRequestAssets);

        vaultConfig.owner = config.get("owner").toAddress();
        vaultConfig.guardian = config.get("guardian").toAddress();
        vaultConfig.manager = config.get("manager").toAddress();
        vaultConfig.keeper = config.get("keeper").toAddress();

        vaultConfig.premiumCollector = config.get("premium_collector").toAddress();
        vaultConfig.premiumRateBps = config.get("premium_rate_bps").toUint16();
        vaultConfig.maxPremiumRateBps = config.get("max_premium_rate_bps").toUint16();
    }

    function _validateConfig(VaultConfig memory vaultConfig) internal pure {
        require(address(vaultConfig.wrappedVault) != address(0), "wrappedVault is zero");

        require(vaultConfig.owner != address(0), "owner is zero");
        require(vaultConfig.guardian != address(0), "guardian is zero");
        require(vaultConfig.manager != address(0), "manager is zero");
        require(vaultConfig.keeper != address(0), "keeper is zero");

        require(vaultConfig.premiumCollector != address(0), "premium collector is zero");
        require(vaultConfig.maxPremiumRateBps != 0, "maxPremiumRateBps is zero");
        require(vaultConfig.premiumRateBps <= vaultConfig.maxPremiumRateBps, "premiumRateBps too high");
    }

    function _getOptionalAddress(string memory key) internal view returns (address value) {
        Variable memory v = config.get(key);
        if (v.ty.kind == TypeKind.None) return address(0);
        return v.toAddress();
    }

    function _deriveNameAndSymbol(IERC4626 wrappedVault)
        internal
        view
        returns (string memory name_, string memory symbol_)
    {
        IERC20Metadata token = IERC20Metadata(address(wrappedVault));
        symbol_ = string.concat("OC-", token.symbol());
        name_ = string.concat("Covered ", token.name());
    }

    function _deployMetavault(address deployer, VaultConfig memory vaultConfig)
        internal
        returns (CoveredMetavault vault, address implementation)
    {
        (string memory metavaultName, string memory metavaultSymbol) = _deriveNameAndSymbol(vaultConfig.wrappedVault);

        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (
                vaultConfig.wrappedVault,
                metavaultName,
                metavaultSymbol,
                vaultConfig.minimumRequestAssets,
                vaultConfig.premiumCollector,
                vaultConfig.maxPremiumRateBps,
                vaultConfig.premiumRateBps
            )
        );

        address proxy = Upgrades.deployUUPSProxy("CoveredMetavault.sol:CoveredMetavault", initData);
        implementation = Upgrades.getImplementationAddress(proxy);
        vault = CoveredMetavault(proxy);

        vault.grantRole(vault.MANAGER_ROLE(), vaultConfig.manager);
        vault.grantRole(vault.GUARDIAN_ROLE(), vaultConfig.guardian);
        vault.grantRole(vault.KEEPER_ROLE(), vaultConfig.keeper);

        if (vaultConfig.owner != deployer) {
            vault.transferOwnership(vaultConfig.owner);
            console.log("");
            console.log("!!! ACTION REQUIRED !!!");
            console.log("Owner", vaultConfig.owner, "must call acceptOwnership() to complete transfer");
            console.log("");
        }
    }

    function _logDeploymentDetails(
        bool isDryRun,
        uint256 chainId,
        CoveredMetavault vault,
        address implementation,
        VaultConfig memory vaultConfig
    ) internal view {
        string memory title = isDryRun
            ? "================== DRY RUN =================="
            : "================ LIVE DEPLOY ================";

        console.log(title);

        console.log("-------------- VAULT METADATA --------------");
        console.log("Chain ID:", chainId);
        console.log("Metavault Proxy:", address(vault));
        console.log("Metavault Implementation:", implementation);
        console.log("Metavault Name:", vault.name());
        console.log("Metavault Symbol:", vault.symbol());
        console.log("Wrapped Vault:", address(vaultConfig.wrappedVault));
        console.log("Minimum Request Assets:", vaultConfig.minimumRequestAssets);

        console.log("------------ ROLES & OWNERSHIP -------------");
        console.log(
            string(
                abi.encodePacked(
                    "Deployer Address: ",
                    Strings.toChecksumHexString(msg.sender),
                    " (balance ",
                    Strings.toString(msg.sender.balance),
                    " ETH)"
                )
            )
        );
        console.log("Owner Address:", vaultConfig.owner);
        console.log("Manager Address:", vaultConfig.manager);
        console.log("Guardian Address:", vaultConfig.guardian);
        console.log("Keeper Address:", vaultConfig.keeper);

        console.log("-------------- PREMIUM CONFIG --------------");
        console.log("Premium Collector:", vaultConfig.premiumCollector);
        console.log("Premium Rate (bps):", vaultConfig.premiumRateBps);
        console.log("Max Premium Rate (bps):", vaultConfig.maxPremiumRateBps);

        console.log("============================================");
    }
}

contract DeployMainnetScript is Script, VaultConfigLoader {
    using LibVariable for Variable;

    function run() public {
        string memory configPath = vm.envString("CONFIG_PATH");
        _loadConfig(configPath, true);

        uint256 mainnetChainId = config.resolveChainId("mainnet");

        VaultConfig memory vaultConfig = _readConfig();
        _validateConfig(vaultConfig);

        vm.startBroadcast();
        address deployer = msg.sender;
        (CoveredMetavault vault, address implementation) = _deployMetavault(deployer, vaultConfig);
        vm.stopBroadcast();

        _logDeploymentDetails(false, mainnetChainId, vault, implementation, vaultConfig);
    }
}

contract DeployMainnetDryRunScript is Script, VaultConfigLoader {
    using LibVariable for Variable;

    function run() public {
        // Load config and set up mainnet fork.
        string memory configPath = vm.envString("CONFIG_PATH");
        _loadConfigAndForks(configPath, false);

        uint256 mainnetChainId = config.resolveChainId("mainnet");
        vm.selectFork(forkOf[mainnetChainId]);

        VaultConfig memory vaultConfig = _readConfig();
        _validateConfig(vaultConfig);

        // Uncomment below to use dummy deployer:
        /*
            uint256 deployerKey = 0xA11CE;
            address deployer = vm.addr(deployerKey);
            vm.deal(deployer, 10 ether);
            vm.startBroadcast(deployerKey);
        */
        vm.startBroadcast();
        address deployer = msg.sender;
        (CoveredMetavault vault, address implementation) = _deployMetavault(deployer, vaultConfig);
        vm.stopBroadcast();

        require(vault.asset() == address(vaultConfig.wrappedVault), "asset mismatch");
        require(vault.premiumCollector() == vaultConfig.premiumCollector, "premiumCollector mismatch");
        require(vault.premiumRateBps() == vaultConfig.premiumRateBps, "premiumRateBps mismatch");
        require(vault.maxPremiumRateBps() == vaultConfig.maxPremiumRateBps, "maxPremiumRateBps mismatch");
        require(vault.hasRole(vault.MANAGER_ROLE(), vaultConfig.manager), "manager role missing");
        require(vault.hasRole(vault.GUARDIAN_ROLE(), vaultConfig.guardian), "guardian role missing");
        require(vault.hasRole(vault.KEEPER_ROLE(), vaultConfig.keeper), "keeper role missing");

        console.log("Dry-run successful");
        _logDeploymentDetails(true, mainnetChainId, vault, implementation, vaultConfig);
    }
}
