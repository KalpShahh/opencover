// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MockERC4626} from "script/helpers/MockERC4626.sol";
import {MAX_PREMIUM_RATE_BPS} from "src/Constants.sol";
import {CoveredMetavault} from "src/CoveredMetavault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";

abstract contract CoveredMetavaultTestBase is Test {
    uint256 constant DEPOSIT_REQUEST_ID = 0;
    uint256 constant INITIAL_BALANCE = 10000e18;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    // Vault wallets.
    address immutable vaultOwner = makeAddr("vaultOwner");
    address immutable guardian = makeAddr("guardian");
    address immutable manager = makeAddr("manager");
    address immutable keeper = makeAddr("keeper");
    address immutable premiumCollector = makeAddr("premiumCollector");

    // User wallets.
    address immutable owner = makeAddr("owner");
    address immutable receiver = makeAddr("receiver");
    address immutable other = makeAddr("other");

    CoveredMetavault vault;
    MockERC20 underlyingAsset;
    MockERC4626 asset;

    function setUp() public virtual {
        vm.startPrank(vaultOwner);

        // Deploy mock ERC-4626 asset (share token) backed by a mock underlying asset.
        underlyingAsset = new MockERC20("Mock USDC", "mUSDC");
        asset = new MockERC4626(underlyingAsset, "Mock Yield USDC", "myUSDC");

        // Deploy vault proxy and implementation.
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (IERC4626(asset), "Covered Mock Yield USDC", "OC-myUSDC", 0, premiumCollector, MAX_PREMIUM_RATE_BPS, 0)
            )
        );
        vault = CoveredMetavault(proxy);

        vm.label(address(asset), "asset");
        vm.label(address(underlyingAsset), "underlyingAsset");
        vm.label(address(vault), "vault");

        // Grant roles to vault wallets.
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vault.grantRole(vault.MANAGER_ROLE(), manager);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);

        vm.stopPrank();

        // Mint initial balances and approve vault.
        _mintAndApprove(owner, INITIAL_BALANCE);
        _mintAndApprove(other, INITIAL_BALANCE);
    }

    function _mintAndApprove(address to, uint256 amount) internal {
        underlyingAsset.mint(to, amount);
        uint256 allowance = asset.allowance(to, address(vault));

        vm.startPrank(to);
        underlyingAsset.approve(address(asset), amount);
        asset.deposit(amount, to);
        asset.approve(address(vault), allowance + amount);
        vm.stopPrank();
    }

    /// @dev Configure the premium rate (collector is set during initialisation).
    function _setPremiumRate(uint16 rateBps) internal {
        vm.prank(manager);
        vault.setPremiumRateBps(rateBps);
    }

    function _setMinimumRequestAssets(uint96 minimumAssets) internal {
        vm.prank(manager);
        vault.setMinimumRequestAssets(minimumAssets);
    }

    function _requestDeposit(uint256 assets, address controller_, address owner_) internal {
        vm.prank(owner_);
        vault.requestDeposit(assets, controller_, owner_);
    }

    function _settle() internal {
        vm.prank(keeper);
        vault.settle(0, new uint256[](0));
    }

    function _settle(uint256 expectedPendingAssets) internal {
        vm.prank(keeper);
        vault.settle(expectedPendingAssets, new uint256[](0));
    }

    function _settle(uint256 expectedPendingAssets, uint256 redeemRequestId) internal {
        uint256[] memory reqs = new uint256[](1);
        reqs[0] = redeemRequestId;
        vm.prank(keeper);
        vault.settle(expectedPendingAssets, reqs);
    }

    function _settle(uint256 expectedPendingAssets, uint256[] memory redeemRequestIds) internal {
        vm.prank(keeper);
        vault.settle(expectedPendingAssets, redeemRequestIds);
    }

    function _deposit(uint256 assets, address receiver_, address controller_) internal returns (uint256 shares) {
        vm.prank(controller_);
        shares = vault.deposit(assets, receiver_, controller_);
        assertGt(shares, 0);
    }

    function _mintSharesTo(address account, uint256 assets) internal returns (uint256 shares) {
        _requestDeposit(assets, account, account);
        _settle();
        return _deposit(assets, account, account);
    }
}
