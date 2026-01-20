// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IERC7575SingleAsset
/// @notice Single-asset ERC-7575 semantics: ERC-4626 vault with integrated ERC-20 shares and `share()`.
/// @dev Equivalent to `IERC4626` plus `share()` for vaults whose share token is this contract.
interface IERC7575SingleAsset is IERC4626 {
    /// @notice Share token address.
    /// @dev For single-asset vaults, SHOULD return `address(this)`.
    /// @return shareTokenAddress ERC-20 share token address.
    function share() external view returns (address shareTokenAddress);
}
