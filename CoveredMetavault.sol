// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

import {
    DEPOSIT_REQUEST_ID,
    MAX_PREMIUM_RATE_BPS,
    MAX_PREMIUM_YEARS,
    REDEEM_AUTO_CLAIMABLE_DELAY,
    SECONDS_IN_YEAR
} from "./Constants.sol";
import {ICoveredMetavault} from "./interfaces/ICoveredMetavault.sol";
import {IERC7540Deposit, IERC7540Redeem} from "./interfaces/IERC7540.sol";
import {IERC7540CancelDeposit, IERC7540CancelRedeem} from "./interfaces/IERC7540Cancel.sol";
import {IERC7575SingleAsset} from "./interfaces/IERC7575.sol";
import {PercentageLib} from "./libraries/PercentageLib.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CoveredMetavault
/// @notice A covered vault implementing ERC-7540 asynchronous operations.
contract CoveredMetavault is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    ICoveredMetavault
{
    using SafeERC20 for IERC20;
    using Math for uint256;
    using PercentageLib for uint256;

    struct DepositStorage {
        /// @dev Last epoch this controller was synced to.
        uint64 lastSyncedEpoch;
        /// @dev Pending assets recorded for the last synced epoch.
        uint256 pendingAssets;
        /// @dev Claimable shares for the controller.
        uint256 claimableShares;
    }

    struct EpochAllocation {
        /// @dev Total pre-minted deposit shares for the epoch.
        uint256 totalShares;
        /// @dev Total deposit assets settled into the epoch.
        uint256 totalAssets;
    }

    struct RedeemStorage {
        /// @dev Total pending redemption shares for this controller (sum of all pending requests).
        uint256 pendingShares;
        /// @dev Total claimable redemption shares for this controller after settlement.
        uint256 claimableShares;
        /// @dev Total claimable redemption assets for this controller after settlement.
        uint256 claimableAssets;
        /// @dev Last redeem request ID created by this controller.
        uint256 lastRedeemRequestId;
    }

    struct RedeemRequestStorage {
        /// @dev Total shares for this request.
        uint256 shares;
        /// @dev Controller authorised for this request.
        address controller;
        /// @dev Timestamp when the request was created.
        uint64 timestamp;
        /// @dev Whether the request has been settled.
        bool settled;
    }

    /// @custom:storage-location erc7201:opencover.storage.CoveredMetavault
    struct VaultStorage {
        /// @dev Total tracked assets that entered through regular operations.
        uint256 totalTrackedAssets;
        /// @dev Total pending assets.
        uint256 totalPendingAssets;
        /// @dev Monotonic counter for unique redemption request IDs.
        uint256 lastRedeemRequestId;
        /// @dev Total claimable redemption shares across all controllers.
        uint256 totalClaimableRedeemShares;
        /// @dev Total claimable redemption assets reserved for settled redemptions across all controllers.
        uint256 totalClaimableRedeemAssets;
        /// @dev Current epoch (increments on settlement).
        uint64 currentEpoch;
        /// @dev Last timestamp when premium was streamed.
        uint64 lastPremiumTimestamp;
        /// @dev Yearly premium rate in basis points.
        uint16 premiumRateBps;
        /// @dev Maximum yearly premium rate in basis points configured for this vault.
        uint16 maxPremiumRateBps;
        /// @dev Unused reserved space for future use.
        uint32 __reserved0;
        /// @dev Address to receive streamed premium.
        address premiumCollector;
        /// @dev Minimum amount of underlying assets required for new asynchronous requests.
        uint96 minimumRequestAssets;
        /// @dev Current owner of the metavault.
        address owner;
        /// @dev Address of the pending owner awaiting acceptance.
        address pendingOwner;
        /// @dev Per-controller deposits.
        mapping(address => DepositStorage) deposits;
        /// @dev Per-controller redemptions.
        mapping(address => RedeemStorage) redeems;
        /// @dev Redemption requests by globally unique request ID.
        mapping(uint256 => RedeemRequestStorage) redeemRequests;
        /// @dev Per-epoch allocation snapshot for deterministic unit assignment on sync.
        mapping(uint64 => EpochAllocation) epochAllocations;
    }

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @dev ERC-7201 storage slot for `VaultStorage`.
    ///   keccak256(abi.encode(uint256(keccak256("opencover.storage.CoveredMetavault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant VAULT_STORAGE_LOCATION = 0xa0a7f1e96a5f62ae5c47275f54e006dddba4e3ec9023fe5a6a0c618495bc5300;

    /// @dev Returns a pointer to the `VaultStorage` struct at the ERC-7201 namespaced location.
    function _getVaultStorage() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VAULT_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // UUPS UPGRADEABLE
    // =========================================================================

    /// @notice Initialise the vault with asset and metadata.
    /// @dev Must be called once via proxy.
    /// @param asset_ ERC-4626 vault whose shares are held by this metavault (the wrapped vault).
    /// @param name_ Name for the metavault share token.
    /// @param symbol_ Symbol for the metavault share token.
    /// @param minimumRequestAssets_ Minimum underlying vault assets required for async requests. Set 0 to disable.
    /// @param premiumCollector_ Initial premium collector address. Cannot be zero.
    /// @param maxPremiumRateBps_ Maximum annual premium rate in basis points for this vault.
    /// @param premiumRateBps_ Initial annual premium rate in basis points.
    function initialize(
        IERC4626 asset_,
        string memory name_,
        string memory symbol_,
        uint96 minimumRequestAssets_,
        address premiumCollector_,
        uint16 maxPremiumRateBps_,
        uint16 premiumRateBps_
    ) public initializer {
        require(premiumCollector_ != address(0), ZeroAddress());
        require(premiumCollector_ != address(this), InvalidPremiumCollector(premiumCollector_));
        require(maxPremiumRateBps_ <= MAX_PREMIUM_RATE_BPS, MaxPremiumRateTooHigh(maxPremiumRateBps_));
        require(premiumRateBps_ <= maxPremiumRateBps_, PremiumRateTooHigh(premiumRateBps_));
        // Sniff test: require wrapped vault to expose `convertToAssets(uint256)`.
        _requireConvertToAssets(asset_);

        // __UUPSUpgradeable_init();

        __ReentrancyGuardTransient_init();
        __AccessControl_init();
        __Pausable_init();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);

        _grantRole(OWNER_ROLE, msg.sender);
        _setRoleAdmin(MANAGER_ROLE, OWNER_ROLE);
        _setRoleAdmin(KEEPER_ROLE, OWNER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, OWNER_ROLE);

        VaultStorage storage $ = _getVaultStorage();
        $.owner = msg.sender;
        $.currentEpoch = 0;
        $.minimumRequestAssets = minimumRequestAssets_;
        $.premiumCollector = premiumCollector_;
        $.maxPremiumRateBps = maxPremiumRateBps_;
        $.premiumRateBps = premiumRateBps_;
    }

    /// @dev This function should revert when the caller is not authorised to upgrade the contract.
    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}

    // =========================================================================
    // ERC-7575 SINGLE-ASSET VAULT
    // =========================================================================

    /// @inheritdoc IERC7575SingleAsset
    function share() external view override returns (address shareTokenAddress) {
        return address(this);
    }

    // =========================================================================
    // ERC-165
    // =========================================================================

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override (AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        // NOTE: Do NOT claim ERC-7540 operator interfaces. Only the core async deposit/redeem interfaces are supported.
        // The operator interface is intentionally out of scope for this implementation for security reasons.
        return interfaceId == type(ICoveredMetavault).interfaceId || interfaceId == type(IERC7540Deposit).interfaceId
            || interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7575SingleAsset).interfaceId
            || interfaceId == type(IERC7540CancelDeposit).interfaceId
            || interfaceId == type(IERC7540CancelRedeem).interfaceId || super.supportsInterface(interfaceId);
    }

    // =========================================================================
    // ERC-7540 ASYNC DEPOSITS
    // =========================================================================

    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        require(assets != 0, ZeroAssets());
        require(controller == owner, InvalidController(controller)); // Intentional spec deviation for better security.
        require(owner == msg.sender, InvalidOwner(owner));

        _requireMinimumRequestAssets(assets);

        IERC20 assetToken = IERC20(asset());
        uint256 balanceBefore = assetToken.balanceOf(address(this));

        // Pull assets into the vault & track them. Requires prior approval by the owner. Reverts if not enough balance.
        _pullAssets(owner, assets);

        // Check and disallow fee-on-transfer assets (rebasing assets are also not supported).
        uint256 received = assetToken.balanceOf(address(this)) - balanceBefore;
        require(received == assets, UnsupportedAsset());

        // Roll previous epoch's pending assets to claimable.
        _syncEpoch(controller);

        VaultStorage storage $ = _getVaultStorage();
        DepositStorage storage depositStorage = $.deposits[controller];
        // New requests are pending until settled by the vault.
        depositStorage.pendingAssets += assets;
        $.totalPendingAssets += assets;

        emit DepositRequest(controller, owner, DEPOSIT_REQUEST_ID, msg.sender, assets);

        return DEPOSIT_REQUEST_ID;
    }

    /// @inheritdoc IERC7540CancelDeposit
    /// @dev Synchronous cancellation: emits both CancelDepositRequest and CancelDepositClaim events
    ///      in a single transaction for ERC-7887 compatibility, as the refund is immediate.
    function cancelDepositRequest(uint256 requestId, address controller, address receiver)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        require(controller == msg.sender, InvalidController(controller));
        require(receiver == controller, InvalidReceiver(receiver));

        assets = _cancelDepositRequest(requestId, controller, receiver);
    }

    /// @inheritdoc ICoveredMetavault
    function cancelDepositRequestForController(uint256 requestId, address controller)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 assets)
    {
        assets = _cancelDepositRequest(requestId, controller, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(receiver == controller, InvalidReceiver(receiver)); // Intentional spec deviation for better security.
        require(controller == msg.sender, InvalidController(controller));

        return _claimDeposit(assets, receiver, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        require(receiver == controller, InvalidReceiver(receiver)); // Intentional spec deviation for better security.
        require(controller == msg.sender, InvalidController(controller));

        return _claimMint(shares, receiver, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256, address controller) external view override returns (uint256 pendingAssets) {
        VaultStorage storage $ = _getVaultStorage();
        DepositStorage storage depositStorage = $.deposits[controller];
        // Only pending if recorded for the current epoch.
        return depositStorage.lastSyncedEpoch == $.currentEpoch ? depositStorage.pendingAssets : 0;
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller)
        external
        view
        override
        returns (uint256 claimableAssets)
    {
        return _claimableDepositAssets(controller);
    }

    /// @inheritdoc ICoveredMetavault
    function pushDepositShares(address controller, uint256 assets)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        _claimDeposit(assets, controller, controller);
    }

    /// @inheritdoc ICoveredMetavault
    function totalPendingAssets() external view override returns (uint256) {
        return _getVaultStorage().totalPendingAssets;
    }

    /// @inheritdoc ICoveredMetavault
    function totalTrackedAssets() external view override returns (uint256) {
        return _getVaultStorage().totalTrackedAssets;
    }

    /// @dev Consume controller claimable assets and mint shares to receiver.
    /// @param assets Claimable assets to convert.
    /// @param receiver Share recipient.
    /// @param controller Controller whose claimable units are used.
    /// @return shares Shares minted.
    function _claimDeposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        require(assets != 0, ZeroAssets());
        require(controller != address(0), ZeroAddress());
        require(receiver != address(0), ZeroAddress());

        // Realise any pending from previous epoch into claimable shares.
        _syncEpoch(controller);

        DepositStorage storage depositStorage = _getVaultStorage().deposits[controller];
        uint256 claimableShares = depositStorage.claimableShares;
        require(claimableShares != 0, InsufficientClaimableAssets(controller, 0, assets));

        // Maximum assets this controller can take right now.
        uint256 maxAssets = _convertToAssets(claimableShares, Math.Rounding.Floor);
        require(maxAssets >= assets, InsufficientClaimableAssets(controller, maxAssets, assets));

        // Convert requested assets to shares at current price.
        // NOTE: shares >= assets since totalSupply >= totalAssets (invariant).
        shares = _convertToShares(assets, Math.Rounding.Floor);
        require(claimableShares >= shares, InsufficientClaimableShares(controller, claimableShares, shares));

        // Consume claimable deposit shares and transfer them out of the vault's bucket.
        depositStorage.claimableShares = claimableShares - shares;

        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    /// @dev Mint exact shares to receiver by consuming controller claimable assets.
    /// @param shares Shares to mint.
    /// @param receiver Share recipient.
    /// @param controller Controller whose claimable units are used.
    /// @return assets Claimable assets consumed.
    function _claimMint(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        require(shares != 0, ZeroShares());
        require(controller != address(0), ZeroAddress());
        require(receiver != address(0), ZeroAddress());

        // Realise any pending from previous epoch into claimable shares.
        _syncEpoch(controller);

        DepositStorage storage depositStorage = _getVaultStorage().deposits[controller];
        uint256 claimableShares = depositStorage.claimableShares;
        require(claimableShares >= shares, InsufficientClaimableShares(controller, claimableShares, shares));

        // NOTE: assets >= 1 since ceil((shares * (A+1)) / (S+1)) >= 1 when shares >= 1.
        assets = _convertToAssets(shares, Math.Rounding.Ceil);

        depositStorage.claimableShares = claimableShares - shares;

        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    /// @dev Sync controller to the current epoch and claim era, rolling settled pending deposits into claimable units.
    /// @param controller Controller address to sync.
    function _syncEpoch(address controller) internal {
        VaultStorage storage $ = _getVaultStorage();
        DepositStorage storage depositStorage = $.deposits[controller];
        uint64 currentEpoch = $.currentEpoch;
        uint64 lastSyncedEpoch = depositStorage.lastSyncedEpoch;

        if (lastSyncedEpoch < currentEpoch) {
            uint256 pendingAssets = depositStorage.pendingAssets;

            if (pendingAssets != 0) {
                // Realise the controller's pending deposit into the epoch's distribution.
                EpochAllocation storage epochStorage = $.epochAllocations[lastSyncedEpoch];
                uint256 epochTotalAssets = epochStorage.totalAssets;
                uint256 epochTotalShares = epochStorage.totalShares;

                // Invariants: settlement with non-zero pendings must have created a non-zero snapshot.
                assert(epochTotalAssets != 0 && epochTotalShares != 0);

                uint256 sharesToAssign = pendingAssets.mulDiv(epochTotalShares, epochTotalAssets, Math.Rounding.Floor);

                // Invariant: epoch share price in asset never > 1.
                assert(sharesToAssign >= pendingAssets);

                // Invariant: shares to assign never exceed total epoch shares.
                assert(sharesToAssign <= epochTotalShares);
                depositStorage.claimableShares += sharesToAssign;

                depositStorage.pendingAssets = 0;
            }

            // Controller is now synced to the vault's current epoch.
            depositStorage.lastSyncedEpoch = currentEpoch;
        }
    }

    /// @dev Synchronously cancel a pending deposit request and refund assets.
    function _cancelDepositRequest(uint256 requestId, address controller, address receiver)
        internal
        returns (uint256 assets)
    {
        require(controller != address(0), ZeroAddress());
        require(receiver != address(0), ZeroAddress());
        require(requestId == DEPOSIT_REQUEST_ID, InvalidRequest(requestId));

        VaultStorage storage $ = _getVaultStorage();
        DepositStorage storage depositStorage = $.deposits[controller];

        // Cancellation only applies while the deposit is pending in the current epoch.
        uint64 currentEpoch = $.currentEpoch;
        require(depositStorage.lastSyncedEpoch == currentEpoch, NoPendingDeposit(controller));

        assets = depositStorage.pendingAssets;
        require(assets != 0, NoPendingDeposit(controller));

        uint256 currentTotalPendingAssets = $.totalPendingAssets;

        depositStorage.pendingAssets = 0;
        $.totalPendingAssets = currentTotalPendingAssets - assets;

        emit CancelDepositRequest(controller, requestId, msg.sender);

        // Push assets back to receiver and untrack them.
        _pushAssets(receiver, assets);

        emit CancelDepositClaim(controller, receiver, requestId, msg.sender, assets);
    }

    /// @dev Assets claimable by the controller at the current claim price.
    function _claimableDepositAssets(address controller) internal view returns (uint256 claimableAssets) {
        VaultStorage storage $ = _getVaultStorage();
        uint64 currentEpoch = $.currentEpoch;

        DepositStorage storage depositStorage = $.deposits[controller];
        uint64 lastSyncedEpoch = depositStorage.lastSyncedEpoch;
        uint256 claimableShares = depositStorage.claimableShares;
        uint256 pendingAssets = depositStorage.pendingAssets;

        if (pendingAssets != 0 && lastSyncedEpoch < currentEpoch) {
            EpochAllocation storage epochStorage = $.epochAllocations[lastSyncedEpoch];
            uint256 epochTotalShares = epochStorage.totalShares;
            uint256 epochTotalAssets = epochStorage.totalAssets;

            if (epochTotalAssets != 0 && epochTotalShares != 0) {
                claimableShares += pendingAssets.mulDiv(epochTotalShares, epochTotalAssets, Math.Rounding.Floor);
            }
        }

        if (claimableShares == 0) return 0;

        return _convertToAssets(claimableShares, Math.Rounding.Floor);
    }

    // =========================================================================
    // ERC-7540 ASYNC REDEMPTIONS
    // =========================================================================

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        require(shares != 0, ZeroShares());
        require(controller == owner, InvalidController(controller)); // Intentional spec deviation for better security.
        require(owner == msg.sender, InvalidOwner(owner));

        // NOTE: `minimumRequestAssets` is enforced offchain by the keeper. Small requests can self-settle
        // permissionlessly via `settleMaturedRedemption()` after the maturity delay.

        // Transfer shares into the vault to lock for redemption.
        _transfer(owner, address(this), shares);

        VaultStorage storage $ = _getVaultStorage();

        // Create unique request ID.
        requestId = ++$.lastRedeemRequestId;

        // Record pending shares for this controller and globally.
        RedeemStorage storage redeemStorage = $.redeems[controller];
        redeemStorage.pendingShares += shares;
        redeemStorage.lastRedeemRequestId = requestId;

        RedeemRequestStorage storage redeemRequestStorage = $.redeemRequests[requestId];
        redeemRequestStorage.controller = controller;
        redeemRequestStorage.shares = shares;
        redeemRequestStorage.timestamp = uint64(block.timestamp);
        redeemRequestStorage.settled = false;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);

        return requestId;
    }

    /// @inheritdoc IERC7540CancelRedeem
    /// @dev Synchronous cancellation: emits both CancelRedeemRequest and CancelRedeemClaim events
    ///      in a single transaction for ERC-7887 compatibility, as the refund is immediate.
    function cancelRedeemRequest(uint256 requestId, address controller, address receiver)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(controller == msg.sender, InvalidController(controller));
        require(receiver == controller, InvalidReceiver(receiver));

        VaultStorage storage $ = _getVaultStorage();
        RedeemRequestStorage storage redeemRequestStorage = $.redeemRequests[requestId];

        address requestController = redeemRequestStorage.controller;
        require(requestController != address(0), InvalidRequest(requestId));
        require(requestController == controller, InvalidController(controller));
        require(!redeemRequestStorage.settled, RequestAlreadySettled(requestId));

        shares = redeemRequestStorage.shares;

        RedeemStorage storage redeemStorage = $.redeems[controller];
        uint256 pendingShares = redeemStorage.pendingShares;

        redeemStorage.pendingShares = pendingShares - shares;

        // Synchronous implementation: emit request event for ERC-7887 compatibility before immediate refund.
        emit CancelRedeemRequest(controller, requestId, msg.sender);

        delete $.redeemRequests[requestId];

        _transfer(address(this), receiver, shares);

        emit CancelRedeemClaim(controller, receiver, requestId, msg.sender, shares);
    }

    /// @inheritdoc IERC7540Redeem
    function redeem(uint256 shares, address receiver, address controller)
        public
        override (ERC4626Upgradeable, ICoveredMetavault)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        require(shares != 0, ZeroShares());
        require(controller == msg.sender, InvalidController(controller));
        require(receiver == controller, InvalidReceiver(receiver)); // Intentional spec deviation for better security.

        // Calculate assets to pay out for the given claimable redemption shares using the controller's bucket.
        RedeemStorage storage redeemStorage = _getVaultStorage().redeems[controller];

        uint256 maxShares = redeemStorage.claimableShares;
        require(maxShares >= shares, InsufficientClaimableShares(controller, maxShares, shares));

        uint256 maxAssets = redeemStorage.claimableAssets;

        assets = shares.mulDiv(maxAssets, maxShares, Math.Rounding.Floor);
        require(assets != 0, ZeroAssets());

        _claimRedeem(assets, shares, receiver, controller);
    }

    /// @inheritdoc IERC7540Redeem
    function withdraw(uint256 assets, address receiver, address controller)
        public
        override (ERC4626Upgradeable, ICoveredMetavault)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(assets != 0, ZeroAssets());
        require(controller == msg.sender, InvalidController(controller));
        require(receiver == controller, InvalidReceiver(receiver)); // Intentional spec deviation for better security.

        // Compute the minimum number of claimable redemption shares to burn to withdraw exact assets.
        RedeemStorage storage redeemStorage = _getVaultStorage().redeems[controller];

        uint256 maxAssets = redeemStorage.claimableAssets;
        require(maxAssets >= assets, InsufficientClaimableAssets(controller, maxAssets, assets));

        uint256 maxShares = redeemStorage.claimableShares;
        shares = assets.mulDiv(maxShares, maxAssets, Math.Rounding.Ceil);
        require(maxShares >= shares, InsufficientClaimableShares(controller, maxShares, shares));

        _claimRedeem(assets, shares, receiver, controller);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 pendingShares)
    {
        RedeemRequestStorage storage redeemRequestStorage = _getVaultStorage().redeemRequests[requestId];
        if (redeemRequestStorage.controller != controller || redeemRequestStorage.timestamp == 0) return 0;

        // A request remains pending until explicitly settled either by the controller after maturity or by the keeper.
        return redeemRequestStorage.settled ? 0 : redeemRequestStorage.shares;
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        override
        returns (uint256 claimableShares)
    {
        RedeemRequestStorage storage redeemRequestStorage = _getVaultStorage().redeemRequests[requestId];
        if (redeemRequestStorage.controller != controller || redeemRequestStorage.timestamp == 0) return 0;

        // Claimable only after explicit settlement either by the controller after maturity or by the keeper.
        // NOTE: This returns the original settled share amount and does NOT decrease after `redeem`/`withdraw`
        // is called. Claims are tracked at the controller level via `redeems[controller].claimableShares`.
        // Use `claimableRedeemShares(controller)` to check actual remaining claimable shares.
        return redeemRequestStorage.settled ? redeemRequestStorage.shares : 0;
    }

    /// @inheritdoc ICoveredMetavault
    function pendingRedeemShares(address controller) external view override returns (uint256) {
        return _getVaultStorage().redeems[controller].pendingShares;
    }

    /// @inheritdoc ICoveredMetavault
    function claimableRedeemShares(address controller) external view override returns (uint256) {
        return _getVaultStorage().redeems[controller].claimableShares;
    }

    /// @inheritdoc ICoveredMetavault
    function lastRedeemRequestId(address controller) external view override returns (uint256) {
        return _getVaultStorage().redeems[controller].lastRedeemRequestId;
    }

    /// @dev Consume controller claimable redemption shares and assets and transfer redemption assets to receiver.
    /// @param assets Redemption assets to transfer out.
    /// @param shares Claimable redemption shares to consume from the controller's bucket.
    /// @param receiver Asset recipient.
    /// @param controller Controller whose claimable redemption pool is used.
    function _claimRedeem(uint256 assets, uint256 shares, address receiver, address controller) internal {
        VaultStorage storage $ = _getVaultStorage();
        RedeemStorage storage redeemStorage = $.redeems[controller];

        uint256 maxShares = redeemStorage.claimableShares;
        uint256 maxAssets = redeemStorage.claimableAssets;

        // Invariants: external entry points must enforce capacity checks.
        assert(maxShares >= shares);
        assert(maxAssets >= assets);

        redeemStorage.claimableShares = maxShares - shares;
        redeemStorage.claimableAssets = maxAssets - assets;

        $.totalClaimableRedeemShares -= shares;
        $.totalClaimableRedeemAssets -= assets;

        // Push assets to receiver and untrack them.
        _pushAssets(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    // =========================================================================
    // SETTLEMENT
    // =========================================================================

    /// @inheritdoc ICoveredMetavault
    function settle(uint256 expectedPendingAssets, uint256[] calldata redeemRequestIds)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        VaultStorage storage $ = _getVaultStorage();

        // Verify expected pending asset to match actual pending assets to prevent manipulation.
        // Setting expectedPendingAssets to 0 settles all pending.
        uint256 pendingAssetsTotal = $.totalPendingAssets;
        if (expectedPendingAssets != 0) {
            require(
                pendingAssetsTotal == expectedPendingAssets,
                UnexpectedPendingAssets(expectedPendingAssets, pendingAssetsTotal)
            );
        }

        // Stream premium from settled assets of the previous epoch.
        _streamPremium();

        // Start new epoch.
        uint64 currentEpoch = $.currentEpoch;
        $.currentEpoch = currentEpoch + 1;

        // Move all pending to claimable pools.
        if (pendingAssetsTotal != 0) {
            uint256 newEpochShares = _convertToShares(pendingAssetsTotal, Math.Rounding.Floor);

            // Invariant: totalSupply() >= totalAssets(), so assets->shares >= assets.
            assert(newEpochShares >= pendingAssetsTotal);

            // Pre-mint shares for the new epoch to be claimed by controllers.
            _mint(address(this), newEpochShares);

            // Record allocation snapshot for lazy per-controller assignment.
            EpochAllocation storage epochStorage = $.epochAllocations[currentEpoch];
            epochStorage.totalShares = newEpochShares;
            epochStorage.totalAssets = pendingAssetsTotal;
        }

        $.totalPendingAssets = 0;

        emit DepositsSettled(currentEpoch, pendingAssetsTotal);

        // Settle redemption requests.
        // This is O(n) where n is the number of redemption requests. There's room to optimise if later required.
        uint256 redeemRequestIdsLength = redeemRequestIds.length;
        for (uint256 i = 0; i < redeemRequestIdsLength; ++i) {
            uint256 requestId = redeemRequestIds[i];
            RedeemRequestStorage storage redeemRequestStorage = $.redeemRequests[requestId];

            address controller = redeemRequestStorage.controller;

            require(controller != address(0), InvalidRequest(requestId));
            require(!redeemRequestStorage.settled, RequestAlreadySettled(requestId));

            uint256 shares = redeemRequestStorage.shares;

            redeemRequestStorage.settled = true;

            RedeemStorage storage redeemStorage = $.redeems[controller];
            redeemStorage.pendingShares -= shares;
            redeemStorage.claimableShares += shares;

            // Lock in the asset amount at settlement time.
            uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);
            require(assets != 0, ZeroAssets());

            // Burn the locked shares so they stop affecting pricing/premium.
            _burn(address(this), shares);

            // Record fixed asset claim for this controller and globally.
            redeemStorage.claimableAssets += assets;

            $.totalClaimableRedeemShares += shares;
            $.totalClaimableRedeemAssets += assets;

            emit RedemptionSettled(controller, requestId, shares);
        }
    }

    /// @inheritdoc ICoveredMetavault
    function pushRedeemAssets(address controller, uint256 shares)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        require(controller != address(0), ZeroAddress());
        require(shares != 0, ZeroShares());

        // Settled redemptions only: claim from the controller's fixed redemption bucket.
        RedeemStorage storage redeemStorage = _getVaultStorage().redeems[controller];

        uint256 maxShares = redeemStorage.claimableShares;
        require(maxShares >= shares, InsufficientClaimableShares(controller, maxShares, shares));

        uint256 maxAssets = redeemStorage.claimableAssets;

        uint256 assets = shares.mulDiv(maxAssets, maxShares, Math.Rounding.Floor);
        require(assets != 0, ZeroAssets());

        _claimRedeem(assets, shares, controller, controller);
    }

    /// @inheritdoc ICoveredMetavault
    function settleMaturedRedemption(uint256 requestId) external override whenNotPaused nonReentrant {
        VaultStorage storage $ = _getVaultStorage();
        RedeemRequestStorage storage redeemRequestStorage = $.redeemRequests[requestId];

        address controller = redeemRequestStorage.controller;

        // Check if redemption request exists and not already settled.
        require(controller != address(0), InvalidRequest(requestId));
        require(!redeemRequestStorage.settled, RequestAlreadySettled(requestId));

        // Check if request has matured.
        bool isMature = redeemRequestStorage.timestamp != 0
            && block.timestamp >= uint256(redeemRequestStorage.timestamp) + uint256(REDEEM_AUTO_CLAIMABLE_DELAY);
        require(isMature, RequestNotMatured(requestId));

        // Ensure premium is streamed up to now.
        _streamPremium();

        uint256 shares = redeemRequestStorage.shares;

        redeemRequestStorage.settled = true;

        RedeemStorage storage redeemStorage = $.redeems[controller];
        redeemStorage.pendingShares -= shares;
        redeemStorage.claimableShares += shares;

        // Lock in the asset amount at settlement time.
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);
        require(assets != 0, ZeroAssets());

        // Burn the locked shares so they stop affecting pricing/premium.
        _burn(address(this), shares);

        // Record fixed asset claim for this controller and globally.
        redeemStorage.claimableAssets += assets;

        $.totalClaimableRedeemShares += shares;
        $.totalClaimableRedeemAssets += assets;

        emit RedemptionSettled(controller, requestId, shares);
    }

    // =========================================================================
    // VAULT CONFIG
    // =========================================================================

    /// @inheritdoc ICoveredMetavault
    function setMinimumRequestAssets(uint96 minimumAssets) external override onlyRole(MANAGER_ROLE) {
        VaultStorage storage $ = _getVaultStorage();
        uint96 oldMinimumAssets = $.minimumRequestAssets;

        if (oldMinimumAssets == minimumAssets) return;

        $.minimumRequestAssets = minimumAssets;

        emit MinimumRequestAssetsUpdated(oldMinimumAssets, minimumAssets);
    }

    /// @inheritdoc ICoveredMetavault
    function minimumRequestAssets() external view override returns (uint96) {
        return _getVaultStorage().minimumRequestAssets;
    }

    // =========================================================================
    // PREMIUM STREAMING
    // =========================================================================

    /// @inheritdoc ICoveredMetavault
    function setPremiumCollector(address collector) external override onlyRole(MANAGER_ROLE) {
        require(collector != address(0), ZeroAddress());
        require(collector != address(this), InvalidPremiumCollector(collector));

        VaultStorage storage $ = _getVaultStorage();
        address oldCollector = $.premiumCollector;
        $.premiumCollector = collector;

        emit PremiumCollectorUpdated(oldCollector, collector);
    }

    /// @inheritdoc ICoveredMetavault
    function setPremiumRateBps(uint16 rateBps) external override whenNotPaused nonReentrant onlyRole(MANAGER_ROLE) {
        VaultStorage storage $ = _getVaultStorage();

        // NOTE: Premium rate can change intra-epoch (intentional). The per-vault cap keeps it bounded and transparent
        // to all depositors, letting the manager adjust when market rates move.
        require(rateBps <= $.maxPremiumRateBps, PremiumRateTooHigh(rateBps));

        uint16 oldRateBps = $.premiumRateBps;
        if (rateBps == oldRateBps) return;

        // Settle premium accrued so far at the old rate.
        // Only stream premium after first settlement to preserve the sentinel value (0).
        if ($.lastPremiumTimestamp != 0) _streamPremium();

        $.premiumRateBps = rateBps;

        emit PremiumRateUpdated($.currentEpoch, oldRateBps, rateBps);
    }

    /// @inheritdoc ICoveredMetavault
    function maxPremiumRateBps() external view override returns (uint16) {
        return _getVaultStorage().maxPremiumRateBps;
    }

    /// @inheritdoc ICoveredMetavault
    function premiumRateBps() external view override returns (uint16) {
        return _getVaultStorage().premiumRateBps;
    }

    /// @inheritdoc ICoveredMetavault
    function premiumCollector() external view override returns (address) {
        return _getVaultStorage().premiumCollector;
    }

    /// @dev Core premium streaming logic.
    ///      Streams from settled assets after reserving assets for claimable redemptions, compounding per full
    ///      elapsed year and pro-rata for remaining seconds. Reduces the global claimable deposit pool proportionally
    ///      or advances the era if it floors to zero.
    function _streamPremium() internal returns (uint256 assetsStreamed, uint64 duration) {
        VaultStorage storage $ = _getVaultStorage();
        uint64 lastPremiumTimestamp = $.lastPremiumTimestamp;
        uint64 nowTimestamp = uint64(block.timestamp);

        // No premium is streamed 1) before the first epoch or 2) if current timestamp's same as last stream.
        if (lastPremiumTimestamp != 0 && nowTimestamp > lastPremiumTimestamp) {
            duration = nowTimestamp - lastPremiumTimestamp;

            uint16 annualRateBps = $.premiumRateBps;
            // No premium is streamed if the annual rate is zero.
            if (annualRateBps != 0) {
                address collector = $.premiumCollector;

                uint256 assetsBefore = totalAssets();
                // No premium is streamed if there are no settled assets.
                if (assetsBefore != 0) {
                    uint256 assetsAfter = assetsBefore;

                    uint64 fullYears = duration / SECONDS_IN_YEAR;
                    // slither-disable-next-line weak-prng - Modulo used for time arithmetic not for randomness.
                    uint64 remainingSeconds = duration % SECONDS_IN_YEAR;

                    // Bound loop iterations to prevent gas DoS if vault is inactive for extended periods.
                    if (fullYears >= MAX_PREMIUM_YEARS) {
                        fullYears = MAX_PREMIUM_YEARS;
                        remainingSeconds = 0;
                    }

                    // Full years: compounding for each year elapsed.
                    for (uint64 i = 0; i < fullYears; ++i) {
                        uint256 premium = assetsAfter.bps(annualRateBps);
                        if (premium == 0) break; // Early exit if premium is zero.
                        assetsAfter -= premium;
                        if (assetsAfter == 0) break; // Early exit if assets are fully consumed.
                    }

                    // Partial year: pro-rata within the remaining year (no compounding within the partial).
                    if (remainingSeconds != 0 && assetsAfter != 0) {
                        uint256 premium = assetsAfter.annualBpsProRata(annualRateBps, remainingSeconds);
                        if (premium != 0) assetsAfter -= premium;
                    }

                    assetsStreamed = assetsBefore - assetsAfter;

                    // Invariant: streamed premium cannot exceed settled assets.
                    assert(assetsStreamed <= assetsBefore);

                    // Push premium to collector and untrack them.
                    if (assetsStreamed != 0) _pushAssets(collector, assetsStreamed);
                }
            }
        }

        $.lastPremiumTimestamp = nowTimestamp;

        emit PremiumStreamed($.currentEpoch, assetsStreamed, duration);
    }

    // =========================================================================
    // ERC-4626 OVERRIDES
    // =========================================================================

    /// @inheritdoc IERC4626
    /// @dev Assets currently settled in the vault (excluding pending deposits and reserved redemptions).
    ///      Uses internally tracked assets rather than balanceOf to prevent donation/inflation attacks.
    function totalAssets() public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        VaultStorage storage $ = _getVaultStorage();
        uint256 settledAssets = $.totalTrackedAssets - $.totalPendingAssets;
        uint256 claimableRedeemAssetsTotal = $.totalClaimableRedeemAssets;

        // Invariant: settled assets always cover reserved redemptions.
        assert(settledAssets >= claimableRedeemAssetsTotal);

        uint256 unreservedSettledAssets = settledAssets - claimableRedeemAssetsTotal;

        // Invariant: share price never exceeds 1 asset per share.
        assert(totalSupply() >= unreservedSettledAssets);

        return unreservedSettledAssets;
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address receiver) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _claimableDepositAssets(receiver);
    }

    /// @inheritdoc IERC4626
    function maxMint(address receiver) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address controller) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _getVaultStorage().redeems[controller].claimableShares;
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address controller) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _getVaultStorage().redeems[controller].claimableAssets;
    }

    /// @dev Preview functions of ERC-7540 vaults revert.
    function previewDeposit(uint256) public pure override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    /// @dev Preview functions of ERC-7540 vaults revert.
    function previewMint(uint256) public pure override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    /// @dev Preview functions of ERC-7540 vaults revert.
    function previewRedeem(uint256) public pure override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    /// @dev Preview functions of ERC-7540 vaults revert.
    function previewWithdraw(uint256) public pure override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    /// @notice ERC-4626 deposit redirects to the ERC-7540 3 parameter version with `msg.sender` as controller.
    function deposit(uint256 assets, address receiver)
        public
        override (ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        require(receiver == msg.sender, InvalidReceiver(receiver)); // Align ERC-4626 path with ERC-7540 restriction.
        return _claimDeposit(assets, receiver, msg.sender);
    }

    /// @notice ERC-4626 mint redirects to the ERC-7540 3 parameter version with `msg.sender` as controller.
    function mint(uint256 shares, address receiver)
        public
        override (ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        require(receiver == msg.sender, InvalidReceiver(receiver)); // Align ERC-4626 path with ERC-7540 restriction.
        return _claimMint(shares, receiver, msg.sender);
    }

    // =========================================================================
    // PAUSABILITY
    // =========================================================================

    /// @inheritdoc ICoveredMetavault
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc ICoveredMetavault
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // ACCESS CONTROL
    // =========================================================================

    /// @inheritdoc ICoveredMetavault
    function transferOwnership(address newOwner) external override onlyRole(OWNER_ROLE) {
        require(newOwner != address(0), ZeroAddress());

        VaultStorage storage $ = _getVaultStorage();
        $.pendingOwner = newOwner;

        emit OwnershipTransferStarted(msg.sender, newOwner);
    }

    /// @inheritdoc ICoveredMetavault
    function acceptOwnership() external override {
        VaultStorage storage $ = _getVaultStorage();

        require($.pendingOwner == msg.sender, InvalidPendingOwner(msg.sender));

        // Clear pending owner.
        $.pendingOwner = address(0);

        // Revoke role from previous owner and grant role to new owner.
        address previousOwner = $.owner;
        _revokeRole(OWNER_ROLE, previousOwner);
        _grantRole(OWNER_ROLE, msg.sender);

        // Update tracked owner.
        $.owner = msg.sender;

        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    /// @dev Disallow renouncing OWNER_ROLE as the role cannot be re-granted.
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        override (IAccessControl, AccessControlUpgradeable)
    {
        if (role == OWNER_ROLE) revert();
        super.renounceRole(role, callerConfirmation);
    }

    // =========================================================================
    // INTERNAL HELPERS
    // =========================================================================

    /// @dev Pull assets into the vault and track them. Used for deposits.
    ///      Centralises asset accounting to prevent donation/inflation attacks.
    /// @param from Address to pull assets from.
    /// @param amount Amount of assets to pull.
    function _pullAssets(address from, uint256 amount) internal {
        _getVaultStorage().totalTrackedAssets += amount;
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(asset()).safeTransferFrom(from, address(this), amount);
    }

    /// @dev Push assets out of the vault and untrack them. Used for redemptions, cancellations, and premium.
    ///      Centralises asset accounting to prevent donation/inflation attacks.
    /// @param to Address to push assets to.
    /// @param amount Amount of assets to push.
    function _pushAssets(address to, uint256 amount) internal {
        _getVaultStorage().totalTrackedAssets -= amount;
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @dev Sniff test for wrapped ERC-4626: ensure `convertToAssets(uint256)` exists.
    function _requireConvertToAssets(IERC4626 token) internal view {
        (bool ok,) = address(token).staticcall(abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)));
        require(ok, UnsupportedAsset());
    }

    /// @dev Convert `assetAmount` into underlying and assert it meets the configured minimum request threshold.
    function _requireMinimumRequestAssets(uint256 assetAmount) internal view {
        uint96 minimumAssets = _getVaultStorage().minimumRequestAssets;
        if (minimumAssets == 0) return;

        uint256 underlyingAssets = IERC4626(asset()).convertToAssets(assetAmount);
        require(underlyingAssets >= minimumAssets, MinimumRequestAssetsNotMet(minimumAssets, underlyingAssets));
    }
}
