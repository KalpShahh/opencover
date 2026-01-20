// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MockERC4626} from "test/mocks/MockERC4626.sol";

import {PercentageLib} from "src/libraries/PercentageLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC4626FeeOnTransfer
/// @notice ERC-4626-compatible mock that applies a fee on share transfers to simulate unsupported assets.
contract MockERC4626FeeOnTransfer is MockERC4626 {
    using PercentageLib for uint256;

    uint16 internal immutable feeBps;

    constructor(IERC20 underlying_, string memory name_, string memory symbol_, uint16 feeBps_)
        MockERC4626(underlying_, name_, symbol_)
    {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        // For mint and burn bypass fee.
        if (from == address(0) || to == address(0)) return super._update(from, to, value);

        // Take fee in basis points.
        uint256 fee = value.bps(feeBps);
        uint256 valueAfterFee = value - fee;

        super._update(from, to, valueAfterFee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}
