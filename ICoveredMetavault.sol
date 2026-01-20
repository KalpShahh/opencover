// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

import {IERC7540Deposit} from "./IERC7540.sol";
import {IERC7540Redeem} from "./IERC7540.sol";
import {IERC7540CancelDeposit, IERC7540CancelRedeem} from "./IERC7540Cancel.sol";
import {IERC7575SingleAsset} from "./IERC7575.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ICoveredMetavault
/// @notice Interface for a covered vault implementing ERC-7540 asynchronous operations.
interface ICoveredMetavault is
    IAccessControl,
    IERC165,
    IERC7540Deposit,
    IERC7540Redeem,
    IERC7540CancelDeposit,
    IERC7540CancelRedeem,
    IERC7575SingleAsset
{
    // =========================================================================
    // SETTLEMENT
    // =========================================================================

    /// @notice Emitted when deposits are settled and become claimable.
    /// @param epoch Epoch number.
    /// @param assets Total assets settled.
    event DepositsSettled(uint64 indexed epoch, uint256 assets);

    /// @notice Emitted when a redemption request is settled and becomes claimable.
    /// @param controller Controller address.
    /// @param requestId Request identifier.
    /// @param shares Shares settled.
    event RedemptionSettled(address indexed controller, uint256 indexed requestId, uint256 shares);

    /// @notice Stream premium, settle all pending deposits and the given redemption requests in a single operation.
    /// @param expectedPendingAssets Expected total pending assets to settle. Pass 0 to settle all.
    /// @param redeemRequestIds Redemption request IDs to settle.
    /// @custom:oc-access-control Keeper
    function settle(uint256 expectedPendingAssets, uint256[] calldata redeemRequestIds) external;

    /// @notice Settle a matured redemption request. Anyone may call after the auto-claimable delay.
    /// @dev Onchain exit guarantee for exceptional keeper stalls.
    /// @param requestId Matured redemption request ID.
    function settleMaturedRedemption(uint256 requestId) external;

    /// @notice Cancel a pending deposit request on behalf of a controller and refund the assets immediately.
    /// @param requestId Request identifier (0 for aggregated deposits).
    /// @param controller Controller whose pending request is cancelled and recipient of the refund.
    /// @return assets Amount of assets refunded to the controller.
    /// @custom:oc-access-control Keeper
    function cancelDepositRequestForController(uint256 requestId, address controller) external returns (uint256 assets);

    /// @notice Push settled deposit assets to mint shares for the controller.
    /// @param controller Controller whose settled deposit assets to consume and receive shares.
    /// @param assets Claimable assets to convert into shares.
    /// @custom:oc-access-control Keeper
    function pushDepositShares(address controller, uint256 assets) external;

    /// @notice Push settled redemption shares to deliver assets to the controller.
    /// @param controller Controller whose settled redemption shares to consume and receive assets.
    /// @param shares Amount of claimable redemption shares to burn for assets.
    /// @custom:oc-access-control Keeper
    function pushRedeemAssets(address controller, uint256 shares) external;

    /// @notice Total pending assets.
    function totalPendingAssets() external view returns (uint256 assets);

    /// @notice Total tracked assets that entered through regular operations.
    function totalTrackedAssets() external view returns (uint256 assets);

    /// @notice Total shares pending redemption for a controller that are not yet settled.
    /// @param controller Controller address whose pending redeem shares to query.
    /// @return shares Total pending redeem shares.
    function pendingRedeemShares(address controller) external view returns (uint256 shares);

    /// @notice Total claimable redemption shares for a controller that have been settled.
    /// @param controller Controller address whose claimable redeem shares to query.
    /// @return shares Total claimable redeem shares.
    function claimableRedeemShares(address controller) external view returns (uint256 shares);

    /// @notice Last redemption request ID for a controller.
    /// @dev Returns 0 if the controller has not created any redemption requests.
    /// @param controller Controller address whose last request ID to query.
    /// @return requestId Last redemption request ID for the controller.
    function lastRedeemRequestId(address controller) external view returns (uint256 requestId);

    // =========================================================================
    // PREMIUM STREAMING
    // =========================================================================

    /// @notice Emitted after attempting to stream premium from the settled pool.
    /// @param epoch Epoch number of the streaming.
    /// @param assets Amount of premium assets transferred to the collector (may be 0).
    /// @param duration Time elapsed since the last premium streaming, in seconds (may be 0).
    event PremiumStreamed(uint64 indexed epoch, uint256 assets, uint64 duration);

    /// @notice Emitted when the premium collector address is updated.
    /// @param oldCollector Old premium collector.
    /// @param newCollector New premium collector.
    event PremiumCollectorUpdated(address oldCollector, address newCollector);

    /// @notice Emitted when the yearly premium rate is updated.
    /// @param epoch Epoch number of the update.
    /// @param oldRateBps Old yearly premium rate in basis points.
    /// @param newRateBps New yearly premium rate in basis points.
    event PremiumRateUpdated(uint64 indexed epoch, uint16 oldRateBps, uint16 newRateBps);

    /// @notice Set the premium collector address.
    /// @param collector Address to receive streamed premium.
    /// @custom:oc-access-control Manager
    function setPremiumCollector(address collector) external;

    /// @notice Set the annual premium rate in basis points. Setting the rate to zero disables premium streaming.
    /// @dev Bounded by the per-vault max premium rate and the global max premium cap.
    /// @param rateBps Annual premium rate in basis points.
    /// @custom:oc-access-control Manager
    function setPremiumRateBps(uint16 rateBps) external;

    /// @notice Maximum annual premium rate in basis points configured for this vault.
    function maxPremiumRateBps() external view returns (uint16);

    /// @notice Annual premium rate in basis points.
    function premiumRateBps() external view returns (uint16);

    /// @notice Address receiving streamed premium.
    function premiumCollector() external view returns (address);

    // =========================================================================
    // VAULT CONFIG
    // =========================================================================

    /// @notice Emitted when the minimum assets required for asynchronous requests are updated.
    /// @param oldMinimumAssets Previously configured minimum expressed in the underlying asset of the vault asset.
    /// @param newMinimumAssets Newly configured minimum expressed in the underlying asset of the vault asset.
    event MinimumRequestAssetsUpdated(uint96 oldMinimumAssets, uint96 newMinimumAssets);

    /// @notice Update the minimum amount of underlying assets required for new deposit and redeem requests.
    /// @param minimumAssets Minimum expressed in the underlying asset of the ERC-4626 asset token.
    /// @custom:oc-access-control Manager
    function setMinimumRequestAssets(uint96 minimumAssets) external;

    /// @notice Minimum amount of underlying assets required for new deposit and redeem requests.
    function minimumRequestAssets() external view returns (uint96);

    // =========================================================================
    // PAUSABILITY
    // =========================================================================

    /// @notice Pause user-facing deposit, redeem and settlement operations.
    /// @custom:oc-access-control Guardian
    function pause() external;

    /// @notice Unpause user-facing deposit, redeem and settlement operations.
    /// @custom:oc-access-control Guardian
    function unpause() external;

    // =========================================================================
    // ACCESS CONTROL
    // =========================================================================

    /// @notice Emitted when ownership transfer is initiated.
    /// @param previousOwner Current owner address initiating the transfer.
    /// @param newOwner Pending owner address.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when ownership of the contract is transferred.
    /// @param previousOwner Previous owner address.
    /// @param newOwner New owner address.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Initiate ownership transfer to a new account. The new owner must call acceptOwnership to complete.
    /// @param newOwner New owner address. Cannot be zero.
    /// @custom:oc-access-control Owner
    function transferOwnership(address newOwner) external;

    /// @notice Accept ownership of the contract. Must be called by the pending owner.
    function acceptOwnership() external;

    // =========================================================================
    // SIGNATURE DISAMBIGUATION WITH ERC-4626
    // =========================================================================

    /// @inheritdoc IERC7540Redeem
    function redeem(uint256 shares, address receiver, address controller)
        external
        override (IERC4626, IERC7540Redeem)
        returns (uint256 assets);

    /// @inheritdoc IERC7540Redeem
    function withdraw(uint256 assets, address receiver, address controller)
        external
        override (IERC4626, IERC7540Redeem)
        returns (uint256 shares);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error ZeroAssets();
    error ZeroShares();
    error ZeroAddress();
    error InvalidPendingOwner(address caller);
    error InvalidController(address controller);
    error InvalidOwner(address owner);
    error InvalidReceiver(address receiver);
    error UnsupportedAsset();
    error InsufficientClaimableAssets(address controller, uint256 maxAssets, uint256 assets);
    error InsufficientClaimableShares(address controller, uint256 maxShares, uint256 shares);
    error MaxPremiumRateTooHigh(uint16 maxPremiumRateBps);
    error PremiumRateTooHigh(uint16 rateBps);
    error InvalidPremiumCollector(address collector);
    error UnexpectedPendingAssets(uint256 expected, uint256 actual);
    error InvalidRequest(uint256 requestId);
    error RequestAlreadySettled(uint256 requestId);
    error RequestNotMatured(uint256 requestId);
    error NoPendingDeposit(address controller);
    error MinimumRequestAssetsNotMet(uint256 minimum, uint256 provided);
}
