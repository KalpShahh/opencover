// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

/// @title IERC7540Operator
/// @notice Operator delegation for ERC-7540 vaults.
/// @dev Operators authorised by a controller may act on the controller's behalf.
interface IERC7540Operator {
    /// @notice Emitted when a controller authorises or revokes an operator.
    /// @param controller Controller granting or revoking rights.
    /// @param operator Operator address.
    /// @param approved True if authorised, false if revoked.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Authorises or revokes an operator for the caller.
    /// @param operator Operator address.
    /// @param approved True to authorise, false to revoke.
    /// @return success True if the operation succeeded.
    function setOperator(address operator, bool approved) external returns (bool success);

    /// @notice Return whether an operator is authorised for a controller.
    /// @param controller Controller address.
    /// @param operator Operator address.
    /// @return status True if authorised.
    function isOperator(address controller, address operator) external view returns (bool status);
}

/// @title IERC7540Deposit
/// @notice Asynchronous deposit requests and claims.
/// @dev Lifecycle: request deposit -> settle -> claim via controller-aware `deposit`/`mint`.
interface IERC7540Deposit {
    /// @notice Emitted on deposit request.
    /// @param controller Controller authorised for the request.
    /// @param owner Asset owner.
    /// @param requestId Request identifier.
    /// @param sender Request submitter.
    /// @param assets Asset amount.
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Submit a deposit request.
    /// @param assets Asset amount.
    /// @param controller Controller for the resulting shares.
    /// @param owner Asset owner.
    /// @return requestId Request identifier.
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Pending assets for a deposit request.
    /// @param requestId Request identifier.
    /// @param controller Controller address.
    /// @return pendingAssets Pending asset amount.
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);

    /// @notice Claimable assets for a settled deposit request.
    /// @param requestId Request identifier.
    /// @param controller Controller address.
    /// @return claimableAssets Claimable asset amount.
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    /// @notice Claim shares from settled deposit requests.
    /// @param assets Asset amount to claim.
    /// @param receiver Share recipient.
    /// @param controller Controller authorised to claim.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claim an exact amount of shares from settled deposit requests.
    /// @param shares Share amount to mint.
    /// @param receiver Share recipient.
    /// @param controller Controller authorised to claim.
    /// @return assets Assets consumed.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}

/// @title IERC7540Redeem
/// @notice Asynchronous redemption requests and withdrawals.
/// @dev Lifecycle: request redeem -> settle -> withdraw/redeem.
interface IERC7540Redeem {
    /// @notice Emitted on redemption request.
    /// @param controller Controller authorised for the request.
    /// @param owner Share owner.
    /// @param requestId Request identifier.
    /// @param sender Request submitter.
    /// @param shares Share amount.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Submit a redemption request.
    /// @param shares Share amount.
    /// @param controller Controller for the resulting assets.
    /// @param owner Share owner.
    /// @return requestId Request identifier.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Pending shares for a redemption request.
    /// @param requestId Request identifier.
    /// @param controller Controller address.
    /// @return pendingShares Pending share amount.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @notice Claimable shares for a settled redemption request.
    /// @dev This function returns the original share amount from the request once settled.
    ///      It does NOT decrease after `redeem` or `withdraw` is called because claims are tracked at the controller
    ///      aggregate level, not per-request. To check actual remaining claimable shares across all requests,
    ///      use `claimableRedeemShares(controller)` instead.
    /// @param requestId Request identifier.
    /// @param controller Controller address.
    /// @return claimableShares Claimable share amount.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);

    /// @notice Claim assets from settled redemption requests.
    /// @param shares Share amount to redeem.
    /// @param receiver Asset recipient.
    /// @param controller Controller authorised to claim.
    /// @return assets Assets withdrawn.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claim an exact amount of assets from settled redemption requests.
    /// @param assets Asset amount to withdraw.
    /// @param receiver Asset recipient.
    /// @param controller Controller authorised to claim.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);
}

/// @title IERC7540
/// @notice Aggregate interface for ERC-7540 asynchronous tokenised vaults.
/// @dev Combines operator delegation, deposit request/claim, and redemption request/claim semantics.
interface IERC7540 is IERC7540Deposit, IERC7540Redeem, IERC7540Operator {}
