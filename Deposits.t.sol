// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MAX_PREMIUM_RATE_BPS} from "src/Constants.sol";
import {CoveredMetavault} from "src/CoveredMetavault.sol";
import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";
import {IERC7540Deposit} from "src/interfaces/IERC7540.sol";
import {IERC7540CancelDeposit} from "src/interfaces/IERC7540Cancel.sol";
import {IERC7575SingleAsset} from "src/interfaces/IERC7575.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626FeeOnTransfer} from "test/mocks/MockERC4626FeeOnTransfer.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title DepositsUnitTest
/// @notice Unit tests for CoveredMetavault async deposit functionality.
contract DepositsUnitTest is CoveredMetavaultTestBase {
    function setUp() public override {
        super.setUp();
        // Setup vault with 10% annual premium.
        _setPremiumRate(1000);
    }

    // Helper to ensure non-zero totalSupply so conversions use the non-initial path.
    function _setupVaultWithClaimedDeposit(uint256 assets) public {
        require(assets > 0, "Assets must be greater than 0");

        _requestDeposit(assets, other, other);
        _settle();
        _deposit(assets, other, other);

        assertGt(vault.totalSupply(), 0);
    }

    // =========================================================================
    // INTERFACE SUPPORT TESTS
    // =========================================================================

    function test_SupportsInterface() public view {
        assertTrue(vault.supportsInterface(type(ICoveredMetavault).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Deposit).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540CancelDeposit).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7575SingleAsset).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertFalse(vault.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_ShareFunction() public view {
        assertEq(vault.share(), address(vault));
    }

    // =========================================================================
    // REQUEST DEPOSIT TESTS
    // =========================================================================

    function test_RequestDeposit_Success() public {
        vm.expectEmit();
        emit IERC7540Deposit.DepositRequest(owner, owner, DEPOSIT_REQUEST_ID, owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 requestId = vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(requestId, DEPOSIT_REQUEST_ID);
        assertEq(asset.balanceOf(address(vault)), DEPOSIT_AMOUNT);
        assertEq(asset.balanceOf(owner), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_RequestDeposit_FeeOnTransfer_UnsupportedAsset() public {
        // Deploy a fee-on-transfer asset and a fresh vault bound to it.
        MockERC20 feeUnderlying = new MockERC20("Mock USDC", "mUSDC");
        MockERC4626FeeOnTransfer feeAsset =
            new MockERC4626FeeOnTransfer(feeUnderlying, "Mock Fee Vault USDC", "mfvUSDC", 100);

        vm.startPrank(vaultOwner);
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (
                    IERC4626(feeAsset),
                    "Covered Fee Vault USDC",
                    "OC-mfvUSDC",
                    0,
                    premiumCollector,
                    MAX_PREMIUM_RATE_BPS,
                    0
                )
            )
        );
        CoveredMetavault feeVault = CoveredMetavault(proxy);
        vm.stopPrank();

        // Fund underlying, acquire vault shares via ERC-4626 deposit, approve the metavault.
        feeUnderlying.mint(owner, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        feeUnderlying.approve(address(feeAsset), DEPOSIT_AMOUNT);
        feeAsset.deposit(DEPOSIT_AMOUNT, owner);
        feeAsset.approve(address(feeVault), DEPOSIT_AMOUNT);

        // Expect revert due to fee-on-transfer causing received != assets.
        vm.expectRevert(ICoveredMetavault.UnsupportedAsset.selector);
        feeVault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.stopPrank();
    }

    function test_RequestDeposit_ZeroAssets() public {
        vm.prank(owner);
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.requestDeposit(0, owner, owner);
    }

    function test_RequestDeposit_ZeroController() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, address(0)));
        vault.requestDeposit(DEPOSIT_AMOUNT, address(0), owner);
    }

    function test_RequestDeposit_RevertWhen_ControllerDiffersFromOwner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, other));
        vault.requestDeposit(DEPOSIT_AMOUNT, other, owner);
    }

    function test_RequestDeposit_InvalidOwner() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidOwner.selector, owner));
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_RequestDeposit_InsufficientBalance() public {
        uint256 excessiveAmount = INITIAL_BALANCE + 1;

        vm.prank(owner);
        asset.approve(address(vault), excessiveAmount);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, INITIAL_BALANCE, excessiveAmount
            )
        );
        vault.requestDeposit(excessiveAmount, owner, owner);
    }

    function test_RequestDeposit_InsufficientAllowance() public {
        address newUser = makeAddr("newUser");

        underlyingAsset.mint(newUser, DEPOSIT_AMOUNT);
        vm.startPrank(newUser);
        underlyingAsset.approve(address(asset), DEPOSIT_AMOUNT);
        asset.deposit(DEPOSIT_AMOUNT, newUser);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, vault, 0, DEPOSIT_AMOUNT)
        );
        vm.prank(newUser);
        vault.requestDeposit(DEPOSIT_AMOUNT, newUser, newUser);
    }

    function test_RequestDeposit_MultipleRequests() public {
        // First request.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Second request (should accumulate).
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
        assertEq(asset.balanceOf(address(vault)), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_RequestDeposit_DifferentControllers() public {
        // Request for controller 1.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Request for controller 2.
        vm.prank(other);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, other, other);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, other), DEPOSIT_AMOUNT / 2);
    }

    function test_RequestDeposit_RevertWhen_BelowMinimumRequestAssets() public {
        uint256 underlyingDeposit = asset.convertToAssets(DEPOSIT_AMOUNT);
        uint96 minimum = uint96(underlyingDeposit * 2);
        _setMinimumRequestAssets(minimum);

        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.MinimumRequestAssetsNotMet.selector, minimum, underlyingDeposit)
        );
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_RequestDeposit_SucceedsAtMinimumRequestAssets() public {
        uint96 minimum = uint96(asset.convertToAssets(DEPOSIT_AMOUNT));
        _setMinimumRequestAssets(minimum);

        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(vault.minimumRequestAssets(), minimum);
    }

    function test_RequestDeposit_RevertWhen_ExchangeRateDropsBelowMinimum() public {
        uint96 minimum = uint96(600e18);
        _setMinimumRequestAssets(minimum);

        // 0.5 underlying per share -> DEPOSIT_AMOUNT corresponds to 500 underlying.
        asset.setAssetsPerShareWad(0.5e18);

        uint256 provided = asset.convertToAssets(DEPOSIT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.MinimumRequestAssetsNotMet.selector, minimum, provided)
        );
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_RequestDeposit_SucceedsWhen_ExchangeRateIncreases() public {
        uint96 minimum = uint96(1500e18);
        _setMinimumRequestAssets(minimum);

        // 2 underlying per share -> DEPOSIT_AMOUNT corresponds to 2000 underlying.
        asset.setAssetsPerShareWad(2e18);

        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
    }

    // =========================================================================
    // PENDING DEPOSIT REQUEST TESTS
    // =========================================================================

    function test_PendingDepositRequest_NoRequest() public view {
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_PendingDepositRequest_WithRequest() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
    }

    function test_PendingDepositRequest_AfterSettlement() public {
        // Make a request.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Settle deposits (moves to next epoch).
        _settle();

        // After settlement, pending should be 0 (moved to claimable).
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    // =========================================================================
    // CLAIMABLE DEPOSIT REQUEST TESTS
    // =========================================================================

    function test_ClaimableDepositRequest_NoRequest() public view {
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_ClaimableDepositRequest_PendingOnly() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_ClaimableDepositRequest_AfterSettlement() public {
        // Make a request.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Settle deposits.
        _settle();

        // Should now be claimable.
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
    }

    function test_ClaimableDepositRequest_MultipleEpochs() public {
        // First request and settlement.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Second request and settlement.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);
        _settle();

        // Should accumulate claimable assets.
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_ClaimableDepositRequest_ReturnsZero_WhenNoDepositButPoolExists() public {
        // Create claimable pool for other.
        _requestDeposit(DEPOSIT_AMOUNT, other, other);
        _settle();

        // Vault has pre-minted shares and settled assets (1:1 ratio initially).
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        // Owner didn't deposit, so no claimable.
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    // =========================================================================
    // SETTLE DEPOSITS TESTS
    // =========================================================================

    function test_SettleDeposits_Success() public {
        // Make a request.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);

        // Settle.
        vm.expectEmit();
        emit ICoveredMetavault.DepositsSettled(0, DEPOSIT_AMOUNT / 2);
        vm.prank(keeper);
        vault.settle(0, new uint256[](0));

        // Verify state changes.
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT / 2);

        // Make another request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);

        vm.expectEmit();
        emit ICoveredMetavault.DepositsSettled(1, DEPOSIT_AMOUNT / 2);
        vm.prank(keeper);
        vault.settle(0, new uint256[](0));

        // Verify state changes.
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT);
    }

    function test_SettleDeposits_NoRequests() public {
        vm.expectEmit();
        emit ICoveredMetavault.DepositsSettled(0, 0);

        vm.prank(keeper);
        vault.settle(0, new uint256[](0));
    }

    function test_SettleDeposits_RevertsWhenExpectedMismatch() public {
        // Request deposits.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Total pending should be 2 * DEPOSIT_AMOUNT.
        uint256 totalPending = vault.totalPendingAssets();
        assertEq(totalPending, 2 * DEPOSIT_AMOUNT);

        // Try to settle with wrong expected amount (should revert).
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredMetavault.UnexpectedPendingAssets.selector,
                DEPOSIT_AMOUNT, // Expected.
                totalPending // Actual.
            )
        );
        vault.settle(DEPOSIT_AMOUNT, new uint256[](0));

        // Settle with correct expected amount (should succeed).
        vm.prank(keeper);
        vault.settle(totalPending, new uint256[](0));

        // Verify deposits were settled.
        assertEq(vault.totalPendingAssets(), 0);
    }

    function test_SettleDeposits_SettlesAllWhenZeroPassed() public {
        // Request deposits.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Total pending should be 2 * DEPOSIT_AMOUNT.
        uint256 totalPending = vault.totalPendingAssets();
        assertEq(totalPending, 2 * DEPOSIT_AMOUNT);

        // Settle with 0 (should settle all pending deposits).
        vm.prank(keeper);
        vault.settle(0, new uint256[](0));

        // Verify all deposits were settled.
        assertEq(vault.totalPendingAssets(), 0);
    }

    // =========================================================================
    // CANCEL DEPOSIT TESTS
    // =========================================================================

    function test_CancelDeposit_Success() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        // Create a pending deposit for the controller.

        // Emit request then claim to mirror ERC-7887 cancel flow.
        vm.expectEmit();
        emit IERC7540CancelDeposit.CancelDepositRequest(owner, DEPOSIT_REQUEST_ID, owner);
        vm.expectEmit();
        emit IERC7540CancelDeposit.CancelDepositClaim(owner, owner, DEPOSIT_REQUEST_ID, owner, DEPOSIT_AMOUNT);

        // The controller cancels its aggregated deposit with request ID zero.
        vm.prank(owner);
        uint256 refunded = vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);

        // The pending amount is cleared and assets are returned to the receiver.
        assertEq(refunded, DEPOSIT_AMOUNT);
        assertEq(asset.balanceOf(owner), INITIAL_BALANCE);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.totalPendingAssets(), 0);
    }

    function test_CancelDeposit_RevertsForZeroReceiver() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // The refund receiver must match the controller (and therefore cannot be zero).
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, address(0));
    }

    function test_CancelDeposit_RevertWhen_ReceiverDiffersFromController() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, other));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, other);
    }

    function test_CancelDeposit_RevertsForInvalidRequestId() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, DEPOSIT_REQUEST_ID + 1));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID + 1, owner, owner);
    }

    function test_CancelDeposit_RevertsForInvalidController() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Only the controller may cancel its aggregated request.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, owner));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);
    }

    function test_CancelDeposit_RevertsWhenNoPending() public {
        // Only current epoch pending deposits are cancellable.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.NoPendingDeposit.selector, owner));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);
    }

    function test_CancelDeposit_RevertsAfterSettlement() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // After settlement deposits are claimable not cancellable.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.NoPendingDeposit.selector, owner));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);
    }

    function test_CancelDeposit_OnlyAffectsSelectedController() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        address controller2 = makeAddr("controller2");
        _mintAndApprove(controller2, INITIAL_BALANCE);
        _requestDeposit(DEPOSIT_AMOUNT / 2, controller2, controller2);

        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);

        vm.prank(owner);
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, controller2), DEPOSIT_AMOUNT / 2);
        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT / 2);
    }

    function test_CancelDeposit_RevertsWhenAlreadyCancelled() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        vm.prank(owner);
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.NoPendingDeposit.selector, owner));
        vault.cancelDepositRequest(DEPOSIT_REQUEST_ID, owner, owner);
    }

    function test_KeeperCancelDeposit_Success() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        vm.expectEmit();
        emit IERC7540CancelDeposit.CancelDepositRequest(owner, DEPOSIT_REQUEST_ID, keeper);
        vm.expectEmit();
        emit IERC7540CancelDeposit.CancelDepositClaim(owner, owner, DEPOSIT_REQUEST_ID, keeper, DEPOSIT_AMOUNT);

        vm.prank(keeper);
        uint256 refunded = vault.cancelDepositRequestForController(DEPOSIT_REQUEST_ID, owner);

        assertEq(refunded, DEPOSIT_AMOUNT);
        assertEq(asset.balanceOf(owner), INITIAL_BALANCE);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.totalPendingAssets(), 0);
    }

    function test_KeeperCancelDeposit_RevertsForUnauthorized() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, vault.KEEPER_ROLE())
        );
        vm.prank(other);
        vault.cancelDepositRequestForController(DEPOSIT_REQUEST_ID, owner);
    }

    function test_KeeperCancelDeposit_RevertsForZeroController() public {
        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        vm.prank(keeper);
        vault.cancelDepositRequestForController(DEPOSIT_REQUEST_ID, address(0));
    }

    function test_KeeperCancelDeposit_RevertsForInvalidRequestId() public {
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, DEPOSIT_REQUEST_ID + 1));
        vm.prank(keeper);
        vault.cancelDepositRequestForController(DEPOSIT_REQUEST_ID + 1, owner);
    }

    function test_KeeperCancelDeposit_RevertsWhenNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.NoPendingDeposit.selector, owner));
        vm.prank(keeper);
        vault.cancelDepositRequestForController(DEPOSIT_REQUEST_ID, owner);
    }

    // =========================================================================
    // DEPOSIT (3-PARAMETER) TESTS
    // =========================================================================

    function test_DepositThreeParameter_Success() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Claim deposit.
        vm.expectEmit(true, true, false, true);
        emit IERC4626.Deposit(owner, owner, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT); // 1:1 conversion initially.

        vm.prank(owner);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(owner), DEPOSIT_AMOUNT);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_DepositThreeParameter_Success_NonInitial() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Claim deposit with realistic conversion.
        vm.prank(owner);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(shares, vault.convertToShares(DEPOSIT_AMOUNT));
        assertEq(vault.balanceOf(owner), shares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_DepositThreeParameter_ZeroAssets() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.ZeroAssets.selector));
        vault.deposit(0, owner, owner);
    }

    function test_DepositThreeParameter_ZeroReceiver() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.deposit(DEPOSIT_AMOUNT, address(0), owner);
    }

    function test_DepositThreeParameter_RevertWhen_ReceiverDiffersFromController() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, receiver));
        vault.deposit(DEPOSIT_AMOUNT, receiver, owner);
    }

    function test_DepositThreeParameter_InsufficientClaimable() public {
        // Make smaller request than what we try to claim.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredMetavault.InsufficientClaimableAssets.selector, owner, DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT
            )
        );
        vault.deposit(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_DepositThreeParameter_InvalidController() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Try to deposit with wrong msg.sender (other instead of owner).
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, owner));
        vault.deposit(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_DepositThreeParameter_PartialClaim() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Claim only part of it.
        uint256 partialAmount = DEPOSIT_AMOUNT / 2;
        vm.prank(owner);
        uint256 shares = vault.deposit(partialAmount, owner, owner);

        assertEq(shares, vault.convertToShares(partialAmount));
        assertEq(vault.balanceOf(owner), shares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT - partialAmount);
    }

    // =========================================================================
    // MINT (3-PARAMETER) TESTS
    // =========================================================================

    function test_MintThreeParameter_Success() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Mint shares (should use exact shares -> assets conversion).
        uint256 sharesToMint = DEPOSIT_AMOUNT; // 1:1 conversion initially.
        vm.expectEmit(true, true, false, true);
        emit IERC4626.Deposit(owner, owner, DEPOSIT_AMOUNT, sharesToMint);

        vm.prank(owner);
        uint256 assets = vault.mint(sharesToMint, owner, owner);

        assertEq(assets, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(owner), sharesToMint);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_MintThreeParameter_Success_NonInitial() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Mint shares based on realistic conversion.
        uint256 sharesToMint = vault.convertToShares(DEPOSIT_AMOUNT);
        vm.prank(owner);
        uint256 assets = vault.mint(sharesToMint, owner, owner);

        assertEq(assets, vault.convertToAssets(sharesToMint));
        assertEq(vault.balanceOf(owner), sharesToMint);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_MintThreeParameter_ZeroShares() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.ZeroShares.selector));
        vault.mint(0, owner, owner);
    }

    function test_MintThreeParameter_ZeroReceiver() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.mint(DEPOSIT_AMOUNT, address(0), owner);
    }

    function test_MintThreeParameter_RevertWhen_ReceiverDiffersFromController() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, receiver));
        vault.mint(DEPOSIT_AMOUNT, receiver, owner);
    }

    function test_MintThreeParameter_InsufficientClaimable() public {
        // Make smaller request than what we try to claim.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredMetavault.InsufficientClaimableShares.selector, owner, DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT
            )
        );
        vault.mint(DEPOSIT_AMOUNT, owner, owner); // Trying to mint shares worth more assets than claimable.
    }

    function test_MintThreeParameter_InvalidController() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Try to mint with wrong msg.sender (other instead of owner).
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, owner));
        vault.mint(DEPOSIT_AMOUNT, owner, owner);
    }

    function test_MintThreeParameter_PartialClaim() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Mint only part of available shares.
        uint256 partialShares = DEPOSIT_AMOUNT / 2;
        vm.prank(owner);
        uint256 assets = vault.mint(partialShares, owner, owner);

        assertEq(assets, vault.convertToAssets(partialShares));
        assertEq(vault.balanceOf(owner), partialShares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT - partialShares);
    }

    function test_MintThreeParameter_ConversionPrecision() public {
        // Test edge case: minting 1 wei of shares when claimable assets exist.

        // Seed initial supply so we avoid the explicit 1:1 initial conversion path.
        _setupVaultWithClaimedDeposit(1e18);

        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Mint minimal shares.
        vm.prank(owner);
        uint256 assets = vault.mint(1, owner, owner);

        assertEq(assets, vault.convertToAssets(1));
        assertEq(vault.balanceOf(owner), 1);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), DEPOSIT_AMOUNT - assets);
    }

    function test_MintThreeParameter_ExactClaimableAmount() public {
        // Test edge case: minting shares that require exactly all claimable assets.

        // Seed initial supply so we avoid the explicit 1:1 initial conversion path.
        _setupVaultWithClaimedDeposit(1e18);

        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        uint256 maxShares = vault.convertToShares(DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 assets = vault.mint(maxShares, owner, owner);

        assertEq(assets, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(owner), maxShares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    // =========================================================================
    // MINT (2-PARAMETER OVERRIDE) TESTS
    // =========================================================================

    function test_Mint_TwoParameter_Success() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Use 2-parameter mint (should redirect to 3-parameter with msg.sender as controller).
        vm.prank(owner);
        uint256 assets = vault.mint(DEPOSIT_AMOUNT, owner);

        assertEq(assets, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(owner), DEPOSIT_AMOUNT);
    }

    function test_Mint_TwoParameter_Success_NonInitial() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Use 2-parameter mint (redirects to 3-param) with non-initial conversion.
        uint256 sharesToMint = vault.convertToShares(DEPOSIT_AMOUNT);
        vm.prank(owner);
        uint256 assets = vault.mint(sharesToMint, owner);

        assertEq(assets, vault.convertToAssets(sharesToMint));
        assertEq(vault.balanceOf(owner), sharesToMint);
    }

    function test_Mint_TwoParameter_ZeroReceiver() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.mint(DEPOSIT_AMOUNT, address(0));
    }

    function test_Mint_TwoParameter_InsufficientClaimable() public {
        // No request made, so no claimable assets.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.InsufficientClaimableShares.selector, owner, 0, DEPOSIT_AMOUNT)
        );
        vault.mint(DEPOSIT_AMOUNT, owner);
    }

    function test_Mint_TwoParameter_RevertWhen_ReceiverDiffersFromSender() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, receiver));
        vault.mint(DEPOSIT_AMOUNT, receiver);
    }

    // =========================================================================
    // DEPOSIT (2-PARAMETER OVERRIDE) TESTS
    // =========================================================================

    function test_Deposit_TwoParameter_Success() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Use 2-parameter deposit (should redirect to 3-parameter with msg.sender as controller).
        vm.prank(owner);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, owner);

        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(owner), DEPOSIT_AMOUNT);
    }

    function test_Deposit_TwoParameter_Success_NonInitial() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Use 2-parameter deposit (redirects to 3-param) with non-initial conversion.
        vm.prank(owner);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, owner);

        assertEq(shares, vault.convertToShares(DEPOSIT_AMOUNT));
        assertEq(vault.balanceOf(owner), shares);
    }

    function test_Deposit_TwoParameter_ZeroReceiver() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.deposit(DEPOSIT_AMOUNT, address(0));
    }

    function test_Deposit_TwoParameter_InsufficientClaimable() public {
        // No request made, so no claimable assets.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.InsufficientClaimableAssets.selector, owner, 0, DEPOSIT_AMOUNT)
        );
        vault.deposit(DEPOSIT_AMOUNT, owner);
    }

    function test_Deposit_TwoParameter_RevertWhen_ReceiverDiffersFromSender() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, receiver));
        vault.deposit(DEPOSIT_AMOUNT, receiver);
    }

    // =========================================================================
    // PUSH DEPOSIT SHARES TESTS
    // =========================================================================

    function test_PushDepositShares_Settled_Succeeds() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        uint256 expectedShares = vault.convertToShares(DEPOSIT_AMOUNT);

        vm.expectEmit();
        emit IERC4626.Deposit(owner, owner, DEPOSIT_AMOUNT, expectedShares);

        vm.prank(keeper);
        vault.pushDepositShares(owner, DEPOSIT_AMOUNT);

        assertEq(vault.balanceOf(owner), expectedShares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_PushDepositShares_RevertsWhen_CallerNotKeeper() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, vault.KEEPER_ROLE())
        );
        vm.prank(other);
        vault.pushDepositShares(owner, DEPOSIT_AMOUNT);
    }

    function test_PushDepositShares_RevertsWhen_InsufficientClaimableAssets() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredMetavault.InsufficientClaimableAssets.selector, owner, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + 1
            )
        );
        vm.prank(keeper);
        vault.pushDepositShares(owner, DEPOSIT_AMOUNT + 1);
    }

    function test_PushDepositShares_RevertsWhen_ZeroAddress() public {
        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        vm.prank(keeper);
        vault.pushDepositShares(address(0), 1);
    }

    function test_PushDepositShares_RevertsWhen_ZeroAssets() public {
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vm.prank(keeper);
        vault.pushDepositShares(owner, 0);
    }

    // =========================================================================
    // MAX DEPOSIT/MINT TESTS
    // =========================================================================

    function test_MaxDeposit_NoClaimable() public view {
        assertEq(vault.maxDeposit(owner), 0);
    }

    function test_MaxDeposit_WithClaimable() public {
        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        assertEq(vault.maxDeposit(owner), DEPOSIT_AMOUNT);
    }

    function test_MaxMint_WithClaimable() public {
        // Ensure conversions use non-initial path.
        _setupVaultWithClaimedDeposit(1e18);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Should equal the shares equivalent of claimable assets.
        assertEq(vault.maxMint(owner), vault.convertToShares(DEPOSIT_AMOUNT));
    }

    // =========================================================================
    // TOTAL PENDING ASSETS TESTS
    // =========================================================================

    function test_TotalPendingAssets_InitialZero() public view {
        assertEq(vault.totalPendingAssets(), 0);
    }

    function test_TotalPendingAssets_AccumulatesSingleController() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, owner, owner);
        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_TotalPendingAssets_AccumulatesMultipleControllers() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.prank(other);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, other, other);

        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_TotalPendingAssets_ResetOnSettle() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.prank(other);
        vault.requestDeposit(DEPOSIT_AMOUNT / 2, other, other);

        assertEq(vault.totalPendingAssets(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);

        _settle();

        assertEq(vault.totalPendingAssets(), 0);
    }

    // =========================================================================
    // TOTAL ASSETS TESTS
    // =========================================================================

    function test_TotalAssets_Initial() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssets_WithPendingRequests() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Total assets should not include pending deposits.
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssets_AfterSettlement() public {
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // After settlement, assets become part of total assets.
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_TotalAssets_AfterClaim() public {
        // Make request, settle, and claim.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        vm.prank(owner);
        vault.deposit(DEPOSIT_AMOUNT, owner, owner);

        // Assets should still be in vault (shares were minted).
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    // =========================================================================
    // TOTAL TRACKED ASSETS TESTS
    // =========================================================================

    function test_TotalTrackedAssets_ReturnsZero_Initially() public view {
        assertEq(vault.totalTrackedAssets(), 0);
    }

    function test_TotalTrackedAssets_IncreasesOnDeposit() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        assertEq(vault.totalTrackedAssets(), DEPOSIT_AMOUNT);
    }

    function test_TotalTrackedAssets_AccumulatesMultipleDeposits() public {
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _requestDeposit(DEPOSIT_AMOUNT, other, other);

        assertEq(vault.totalTrackedAssets(), DEPOSIT_AMOUNT * 2);
    }

    // =========================================================================
    // PREVIEW FUNCTION TESTS (SHOULD REVERT)
    // =========================================================================

    function test_PreviewDeposit_Reverts() public {
        vm.expectRevert();
        vault.previewDeposit(DEPOSIT_AMOUNT);
    }

    function test_PreviewMint_Reverts() public {
        vm.expectRevert();
        vault.previewMint(DEPOSIT_AMOUNT);
    }
}
