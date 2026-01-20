// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MAX_PREMIUM_RATE_BPS} from "src/Constants.sol";
import {CoveredMetavault} from "src/CoveredMetavault.sol";
import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title ConfigUnitTest
/// @notice Unit tests for configuration controls on the Covered Metavault.
contract ConfigUnitTest is CoveredMetavaultTestBase {
    // =========================================================================
    // ERC-7201 STORAGE LOCATION
    // =========================================================================

    function test_ERC7201_StorageLocationIsCorrect() public view {
        bytes32 computedSlot = keccak256(abi.encode(uint256(keccak256("opencover.storage.CoveredMetavault")) - 1))
            & ~bytes32(uint256(0xff));

        assertEq(computedSlot, vault.VAULT_STORAGE_LOCATION());
    }

    // =========================================================================
    // INITIALISE
    // =========================================================================

    function test_Initialize_SetsMinimumRequestAssets() public {
        uint96 minimum = uint96(asset.convertToAssets(DEPOSIT_AMOUNT));

        vm.startPrank(vaultOwner);
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (
                    IERC4626(asset),
                    "Covered Mock Yield USDC",
                    "OC-myUSDC",
                    minimum,
                    premiumCollector,
                    MAX_PREMIUM_RATE_BPS,
                    0
                )
            )
        );
        vm.stopPrank();

        CoveredMetavault minimumVault = CoveredMetavault(proxy);

        assertEq(minimumVault.minimumRequestAssets(), minimum);

        vm.startPrank(owner);
        asset.approve(address(minimumVault), DEPOSIT_AMOUNT);

        uint256 belowUnderlying = asset.convertToAssets(DEPOSIT_AMOUNT / 2);
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.MinimumRequestAssetsNotMet.selector, minimum, belowUnderlying)
        );
        minimumVault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);

        minimumVault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.stopPrank();

        assertEq(minimumVault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
    }

    function test_Initialize_RevertWhen_AssetNotERC4626() public {
        // Deploy a plain ERC-20 and attempt to initialize with it (should fail ERC-4626 probe).
        MockERC20 notVault = new MockERC20("Plain Token", "PLN");

        // Deploy implementation and attempt proxy deployment with initialiser data.
        // The proxy constructor will execute the initialiser and bubble the revert.
        address implementation = address(new CoveredMetavault());
        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (IERC4626(address(notVault)), "Invalid Vault", "INV", uint96(0), premiumCollector, MAX_PREMIUM_RATE_BPS, 0)
        );

        vm.expectRevert(ICoveredMetavault.UnsupportedAsset.selector);
        new ERC1967Proxy(implementation, initData);
    }

    function test_Initialize_SetsPremiumConfig() public {
        uint16 maxPremiumRateBps = 2_000; // 20%
        uint16 initialPremiumRateBps = 1_500; // 15%

        vm.startPrank(vaultOwner);
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (
                    IERC4626(asset),
                    "Covered Mock Yield USDC",
                    "OC-myUSDC",
                    0,
                    premiumCollector,
                    maxPremiumRateBps,
                    initialPremiumRateBps
                )
            )
        );

        CoveredMetavault premiumVault = CoveredMetavault(proxy);

        assertEq(premiumVault.premiumCollector(), premiumCollector);
        assertEq(premiumVault.premiumRateBps(), initialPremiumRateBps);
        assertEq(premiumVault.maxPremiumRateBps(), maxPremiumRateBps);

        vm.stopPrank();
    }

    function test_Initialize_RevertWhen_PremiumRateTooHigh() public {
        uint16 rateTooHigh = MAX_PREMIUM_RATE_BPS + 1;

        address implementation = address(new CoveredMetavault());
        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (
                IERC4626(asset),
                "Covered Mock Yield USDC",
                "OC-myUSDC",
                0,
                premiumCollector,
                MAX_PREMIUM_RATE_BPS,
                rateTooHigh
            )
        );

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.PremiumRateTooHigh.selector, rateTooHigh));
        new ERC1967Proxy(implementation, initData);
    }

    function test_Initialize_RevertWhen_PremiumCapTooHigh() public {
        uint16 maxPremiumRateTooHighBps = MAX_PREMIUM_RATE_BPS + 1;

        address implementation = address(new CoveredMetavault());
        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (IERC4626(asset), "Covered Mock Yield USDC", "OC-myUSDC", 0, premiumCollector, maxPremiumRateTooHighBps, 0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.MaxPremiumRateTooHigh.selector, maxPremiumRateTooHighBps)
        );
        new ERC1967Proxy(implementation, initData);
    }

    function test_Initialize_RevertWhen_PremiumRateAboveCap() public {
        uint16 maxPremiumRateBps = 1_000;
        uint16 premiumRateAboveMaxBps = maxPremiumRateBps + 1;

        address implementation = address(new CoveredMetavault());
        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (
                IERC4626(asset),
                "Covered Mock Yield USDC",
                "OC-myUSDC",
                0,
                premiumCollector,
                maxPremiumRateBps,
                premiumRateAboveMaxBps
            )
        );

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.PremiumRateTooHigh.selector, premiumRateAboveMaxBps));
        new ERC1967Proxy(implementation, initData);
    }

    function test_Initialize_RevertWhen_PremiumCollectorZero() public {
        address implementation = address(new CoveredMetavault());
        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (IERC4626(asset), "Covered Mock Yield USDC", "OC-myUSDC", 0, address(0), MAX_PREMIUM_RATE_BPS, 0)
        );

        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        new ERC1967Proxy(implementation, initData);
    }

    function test_Initialize_RevertWhen_PremiumCollectorSelf() public {
        CoveredMetavault implementation = new CoveredMetavault();

        // Compute the deterministic proxy address before deployment.
        // The proxy will be deployed at this address, so we use it as the invalid premium collector.
        address predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        bytes memory initData = abi.encodeCall(
            CoveredMetavault.initialize,
            (IERC4626(asset), "Covered Mock Yield USDC", "OC-myUSDC", 0, predictedProxy, MAX_PREMIUM_RATE_BPS, 0)
        );

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidPremiumCollector.selector, predictedProxy));
        new ERC1967Proxy(address(implementation), initData);
    }

    // =========================================================================
    // MINIMUM REQUEST ASSET
    // =========================================================================

    function test_SetMinimumRequestAssets_UpdatesValue() public {
        uint96 newMinimum = uint96(vault.minimumRequestAssets() + 1);

        vm.expectEmit();
        emit ICoveredMetavault.MinimumRequestAssetsUpdated(0, newMinimum);
        vm.prank(manager);
        vault.setMinimumRequestAssets(newMinimum);

        assertEq(vault.minimumRequestAssets(), newMinimum);
    }

    function test_SetMinimumRequestAssets_NoOpWhenSameValue() public {
        uint96 current = vault.minimumRequestAssets();

        // Expect no emit and no state change.
        vm.prank(manager);
        vault.setMinimumRequestAssets(current);

        assertEq(vault.minimumRequestAssets(), current);
    }

    function test_SetMinimumRequestAssets_RevertWhen_CallerNotManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, owner, vault.MANAGER_ROLE()
            )
        );
        vm.prank(owner);
        vault.setMinimumRequestAssets(1);
    }
}
