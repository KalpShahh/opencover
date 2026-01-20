// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

/// @title IERC7540CancelDeposit
/// @notice ERC-7540 deposit cancellation (synchronous subset of ERC-7887).
/// @dev Spec: https://eips.ethereum.org/EIPS/eip-7887
interface IERC7540CancelDeposit {
    /// @notice Emitted when cancellation of a pending deposit is requested.
    /// @param controller Controller whose request is cancelled.
    /// @param requestId Request identifier (0 for aggregate implementations).
    /// @param sender Caller submitting the cancellation.
    event CancelDepositRequest(address indexed controller, uint256 indexed requestId, address sender);

    /// @notice Emitted when assets are returned as part of a deposit cancellation.
    /// @param controller Controller whose request is being refunded.
    /// @param receiver Recipient of the refunded assets.
    /// @param requestId Request identifier (0 for aggregate implementations).
    /// @param sender Caller processing the refund.
    /// @param assets Asset amount refunded to the receiver.
    event CancelDepositClaim(
        address indexed controller, address indexed receiver, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Cancel a pending deposit request and refund the assets synchronously.
    /// @param requestId Request identifier (0 for aggregate implementations).
    /// @param controller Controller whose pending request is cancelled.
    /// @param receiver Recipient of the refunded assets.
    /// @return assets Asset amount refunded immediately.
    function cancelDepositRequest(uint256 requestId, address controller, address receiver)
        external
        returns (uint256 assets);
}

/// @title IERC7540CancelRedeem
/// @notice ERC-7540 redemption cancellation (synchronous subset of ERC-7887).
/// @dev Spec: https://eips.ethereum.org/EIPS/eip-7887
interface IERC7540CancelRedeem {
    /// @notice Emitted when cancellation of a pending redemption is requested.
    /// @param controller Controller whose request is cancelled.
    /// @param requestId Request identifier.
    /// @param sender Caller submitting the cancellation.
    event CancelRedeemRequest(address indexed controller, uint256 indexed requestId, address sender);

    /// @notice Emitted when shares are returned as part of a redemption cancellation.
    /// @param controller Controller whose request is being refunded.
    /// @param receiver Recipient of the refunded shares.
    /// @param requestId Request identifier.
    /// @param sender Caller processing the refund.
    /// @param shares Share amount refunded to the receiver.
    event CancelRedeemClaim(
        address indexed controller, address indexed receiver, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Cancel a pending redemption request and refund the shares synchronously.
    /// @param requestId Request identifier.
    /// @param controller Controller whose pending request is cancelled.
    /// @param receiver Recipient of the refunded shares.
    /// @return shares Share amount refunded immediately.
    function cancelRedeemRequest(uint256 requestId, address controller, address receiver)
        external
        returns (uint256 shares);
}
