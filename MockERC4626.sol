// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockERC4626
/// @notice ERC-4626 wrapper with an adjustable exchange rate for testing.
contract MockERC4626 is ERC4626 {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 public assetsPerShareWad;

    constructor(IERC20 underlying_, string memory name, string memory symbol) ERC20(name, symbol) ERC4626(underlying_) {
        assetsPerShareWad = WAD;
    }

    function setAssetsPerShareWad(uint256 newAssetsPerShareWad) external {
        require(newAssetsPerShareWad != 0);
        assetsPerShareWad = newAssetsPerShareWad;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        return assets.mulDiv(WAD, assetsPerShareWad, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256 assets) {
        return shares.mulDiv(assetsPerShareWad, WAD, rounding);
    }
}
