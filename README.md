<img src="https://github.com/user-attachments/assets/b363b8e3-f9d5-4489-8e6c-cbb54b7e5333" width="100" alt="OpenCover Logo"/>

<h1>Covered Metavault contracts &nbsp;&nbsp;<img src="https://img.shields.io/badge/Version-V1-blue" alt="Version" /></h1>

Foundry-based Ethereum smart contract project implementing a covered metavault. The primary contract [`CoveredMetavault`](src/CoveredMetavault.sol) implements [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) asynchronous vault patterns with premium streaming and batch settlement functionality, extending OpenZeppelin's ERC-4626 implementation.

## Overview

**💡 Please see our [Gitbook](https://integrate.opencover.com/zeiNPSbmoJnSDblPJcJK/insured-metavaults) covering product details, business context and integration documentation.**

`CoveredMetavault` wraps an existing ERC-4626 yield-vault and issues covered shares, exposing ERC-7540 async deposit and redemption interfaces with intentional security-focused deviations from the spec (no operator delegation). Users submit async deposit and redeem requests that a keeper settles in batches. All deposit, redeem, and withdraw operations enforce strict `controller == owner == msg.sender` and `receiver == controller` to prevent delegated griefing attacks. The contract has role-based access control (Owner, Manager, Keeper, Guardian) with strict separation of responsibilities.

### Roles & controls

| Role | Function |
| --- | --- |
| Owner | Upgrade implementation, grant/revoke roles. |
| Manager | Set `premiumCollector`, set premium rate (<= max), set `minimumRequestAssets`. |
| Keeper | `settle` epochs (streams premium, pre-mints deposit shares), batch-settle redemptions, push claimable shares/assets, cancel deposits for controllers. |
| Guardian | `pause` / `unpause`. Intended for emergency response. |

### Lifecycle

#### Deposit flow

- **Request:** Users call `requestDeposit()` with assets, receiving a fixed request ID (`DEPOSIT_REQUEST_ID = 0`). All deposits for a controller aggregate into one pending balance.
- **Settlement:** Keeper calls `settle()` to pre-mint shares for all pending deposits at the current exchange rate. An epoch allocation snapshot records the total shares and assets, enabling lazy per-controller share assignment when they sync.
- **Claim:** Users call `deposit()` or `mint()` to transfer their allocated shares from the vault's bucket at the current exchange rate. Keepers can also push shares directly to a controller via `pushDepositShares()` (without requiring a user transaction).
- **Cancellation:** Controllers can cancel pending deposits before settlement via `cancelDepositRequest()`. Keepers can also cancel pending deposit requests returning funds to the controller.

#### Redemption flow

- **Request:** Users call `requestRedeem(..)` with shares, receiving a unique request ID. Shares are transferred to the vault contract (escrowed).
- **Settlement:** Keeper includes request IDs in `settle()` call _**OR**_ after 24 hours (`REDEEM_AUTO_CLAIMABLE_DELAY`) anyone can call `settleMaturedRedemption(requestId)` to settle a pending matured redemption request. Note: an emergency pause halts all operations including this guarantee.
- **Claim:** Users call `redeem()` or `withdraw()` to exchange claimable shares for assets. Keepers can also claim assets on behalf of a controller via `pushRedeemAssets()`.
- **Cancellation:** Only pending (unsettled) requests can be cancelled via `cancelRedeemRequest()`.

#### Parameters

- **Minimum threshold:** `minimumRequestAssets` (in underlying vault's assets) prevents dust requests.
- **Epochs:** Each `settle()` increments the epoch, streams premium, and pre-mints shares for pending deposits.

### Premium model

- **Rate:**
  - Global hard cap: `MAX_PREMIUM_RATE_BPS = 25%` annual.
  - Per-metavault maximum: `maxPremiumRateBps` is set at initialisation and cannot exceed the global cap.
  - Live rate: `premiumRateBps` can be adjusted intra-epoch by the manager between 0 and the vault's `maxPremiumRateBps` to track underwriter/market pricing within the configured maximum. When the rate is changed, accrued premium is streamed first at the old rate to avoid retroactive repricing.
- **Streaming:** Premiums stream from settled assets both when `settle()` runs and immediately before any premium rate change, using yearly compounding per full year then pro-rata for remaining seconds (bounded at `MAX_PREMIUM_YEARS` for gas safety). Pre-minted deposit shares in the vault's bucket devalue proportionally as the asset/share ratio decreases.
- **Collector:** Streamed assets are paid out to `premiumCollector`.

### Invariants & assumptions

- The wrapped-vault shares must be non-fee-on-transfer and the issuing vault must implement the ERC-4626 `convertToAssets()` function. Depositing rebasing shares is not supported.
- `totalAssets()` is the effective protected metavault TVL. It includes assets backing metavault shares (onchain balance minus pending deposits and claimable redemptions).
- Keepers manage the backing cover and must ensure the metavault's TVL never exceeds the underlying coverage protecting deposits.
- Share price never exceeds 1 asset per share (`totalSupply >= totalAssets`), ensuring shares only devalue over time via premium streaming.
- Premium streaming cannot overdraw the vault (`assetsStreamed <= assetsBefore`) and implicitly reduces the value of all shares (including pre-minted deposit shares) via the exchange rate.
- Epoch snapshots fix an _asset:share_ ratio at settlement time. Controllers are assigned shares proportionally to their pending assets using floor rounding, which may leave minor dust shares in the vault bucket.
- ERC-4626 preview functions (`previewDeposit`, `previewMint`, `previewRedeem`, `previewWithdraw`) revert by design. Integrators should use ERC-7540 view functions plus `convertToAssets` / `convertToShares`.

## Repository structure

The repository follows a standard Foundry layout with additional documentation and audit artefacts:

- **`src/` - Core contracts**
  - [`CoveredMetavault.sol`](src/CoveredMetavault.sol): Main metavault implementation, combining ERC-7540 asynchronous flows, premium streaming, epoch-based settlement, upgradeability (UUPS) and role-based access control.
  - `interfaces/`: External interfaces for the metavault (`ICoveredMetavault`) and supported standards (`IERC7540*`, single asset [ERC-7575](https://eips.ethereum.org/EIPS/eip-7575) via `IERC7575`), used by integrators and tests.
  - `libraries/`: Shared utility libraries such as `PercentageLib.sol` used for premium calculations.
  - `Constants.sol`: Constants, e.g. premium rate bounds and redemption maturity parameters.

- **`test/` - Test suites**
  - `unit/`: Unit tests for isolated components (vault accounting, governance, maths, redemption maturity/cancellation, and premium edge cases).
  - `integration/`: End-to-end deposits, premium, and redemption flows across realistic scenarios.
  - `fuzz/`: Property-based tests for deposits/redemptions (pending vs claimable), matured redemptions, rounding, and accounting invariants. Fuzzer rounds 2048, configured in `foundry.toml`.
  - `scenario/`: Multi-epoch and stateful scenarios exercising the redemption backlog, settlement timing, and exit guarantees.
  - `mocks/`: Mock vaults and assets (ERC-20, ERC-4626, fee-on-transfer variants) used across tests.
  - `utils/`: Shared test harnesses (e.g. `CoveredMetavaultTestBase.sol`, `PremiumTestBase.sol`) that set up common state.

- **`script/` - Deployment and development scripts**
  - [`DeployLocalMainnetFork.s.sol`](script/DeployLocalMainnetFork.s.sol): Deploys example metavaults on a mainnet fork (e.g. Smokehouse USDT, Smokehouse USDC, Index Coop hyETH) and seeds test user positions.
  - `DeployLocalDev.s.sol`: Deploys a local mock asset and metavault instance for isolated testing.
  - `CreateLocal*Request.s.sol`, `SettleLocalRequests.s.sol`: Scripts to create and settle deposit/redemption requests for manual testing and demos.
  - `helpers/`: Anvil helpers, mock ERC-20/ERC-4626 contracts.

- **`abi/` - Contract ABI**
  - [`CoveredMetavault.json`](abi/CoveredMetavault.json): Latest metavault ABI.

## Local development

Convenience scripts for common commands are defined in [`package.json`](./package.json). We use Bun in the examples below, but npm and Yarn also work (e.g., `npm run <script>` or `yarn <script>`).

### Start node

#### Start forked mainnet node

```shell
bun run start:fork
# or
bun start
```

Starts an Anvil node (chain ID `31337`) forking Ethereum mainnet at block `23875769` with auto-mining enabled.

Make sure to set `FORGE_RPC_URL` environment variable to point to the local node (e.g., `export FORGE_RPC_URL="http://localhost:8545"`).

#### Start local node

```shell
bun run start:dev
```

Starts an Anvil node (chain ID `31337`) with a blank state.

### Deploy Metavault

#### Forked mainnet deployment

```shell
bun run deploy:fork
# or
bun run deploy
```

The script derives the deployer and test user signers from Anvil's mnemonic and broadcasts using those accounts. It deploys a suite of demo covered metavaults around production ERC-4626 vaults. See `script/DeployLocalMainnetFork.s.sol` for the current list of wrapped vaults and addresses.

The deployment performs setup:
- User 1 receives ~$1.5M [USDT](https://etherscan.io/address/0xdAC17F958D2ee523a2206206994597C13D831ec7), $2.5M [USDC](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), and 314 [WETH](https://etherscan.io/address/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).
- User 2 receives $2.5M USDC.
- User 1's USDT is deposited into Smokehouse USDT, then wrapped into the metavault.
- User 2's USDC is deposited into Morpho Smokehouse USDC, then wrapped into the metavault.
- The test vault keeper joins Nexus Mutual as a member.
- Each metavault is set up with a 10% annual premium.

**Forked mainnet deployment example output:**
```
Script ran successfully.

== Logs ==
  === DEPLOYMENT COMPLETE ===
  USDC metavault deployed at: 0x8867E6162ED2de04f2104E3Aed80ba2BdD3A2a08
  USDT metavault deployed at: 0x8088ac73af880564F3e154f292DC133B0c14bF78
  WETH metavault deployed at: 0xE9cD196cffebA6295d1A4ed57A9E7C5F3Fe0A273
  hyperUSDCm metavault deployed at: 0x76F71aa780356DfB77e9342E6840d44b006aF6E5
  svETH metavault deployed at: 0x415FE5d8B1aB82B456ADd4F76a584c19291cA22a
  CSUSDC metavault deployed at: 0x780f645e421FB330Fd5C6FbafC146685eBd384a3
  Deployer: 0x72a51eB7DCA8Dc1092d348aedfC8d10B8c1E5a11
  User 1: 0xfe0F446555805c63d5eb117B6909fd6B42a48371
  User 2: 0x468d9FeCe8b03F53772Be02349810A57c3F1B36a
  Metavault Keeper: 0x62F5794eFb8644618646e01b3D383df036Fc6613
  Keeper Nexus Mutual member ID: 9442
  Keeper NXM balance: 10000000000000000000000
  === FINAL BALANCES ===
  User 1 USDT balance: 0
  User 1 USDC balance: 1300000000000
  User 2 USDC balance: 2008663000000
  User 1 WETH balance: 314000000000000000000
  User 1 bbqUSDT shares: 0
  User 1 bbqUSDC shares: 1107480697778635206865797
  User 2 bbqUSDC shares: 0
  User 1 hyETH shares: 0
  User 1 OC-bbqUSDT shares: 1413392872958424724374856
  User 2 OC-bbqUSDC shares: 453455203003717738863183
```

#### Local deployment
```shell
bun run deploy:dev
```

The script derives the deployer and test user signers from Anvil's mnemonic and broadcasts using those accounts. Upon successful deployment the asset, vault and signer addresses are printed to the console.

What the local deployment script does:
- Deploys a test asset _Mock USDC_ (_mUSDC_) and a UUPS proxy for `CoveredMetavault`.
- Mints 1000 _mUSDC_ to **User 1** and **User 2**.
  - Creates test deposits across epochs so you can interact immediately:
  - Epoch 0: **User 1** requests a 500 deposit. The deployer settles the epoch.
  - Epoch 1: **User 1** deposits 250 from claimable, then requests another 500. **User 2** requests 1000.
- Final state after the script:
  - **User 1**: pending 500, claimable 250, claimed 250
  - **User 2**: pending 1000

**Local deployment example output:**
```
Script ran successfully.

== Logs ==
  Asset deployed at: 0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f
  Vault deployed at: 0x7a2088a1bFc9d81c55368AE168C2C02570cB814F
  Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  User 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  User 2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
```

### Create deposit request

```shell
bun run local:create-deposit-request
```

Creates a deposit request on the local development environment for User 2. This script is useful for testing deposit flows after deployment. Requires a running local node and deployed contracts with the vault address set in `VAULT_ADDRESS` environment variable.

### Settle requests

```shell
bun run local:settle-requests
```

Settles all pending deposit requests and optionally specific redemption requests. To settle redemption requests, set the `REDEEM_REQUEST_IDS` environment variable with comma-separated request IDs:

```shell
REDEEM_REQUEST_IDS="1,2,3" bun run local:settle-requests
```

Leave `REDEEM_REQUEST_IDS` unset or empty to settle deposits only.

### Create redemption request

```shell
bun run local:create-redemption-request
```

Creates a redemption request for 100 vault shares from User 2. The script automatically claims any pending deposits first to maximise available shares, then requests redemption. Prints the request ID which can be used with the settle script.

### Setup end-to-end test state

```shell
bun run local:setup-e2e-test
```

Sets up state suitable for the settlement engine's end-to-end test. Deploys the forked mainnet setup, creates deposit requests, settles them, and creates redemption and deposit requests to prepare for settlement engine testing.

### Snapshot and revert state

```shell
bun run snapshot:fork
```

Creates a snapshot of the forked mainnet state. Returns a snapshot ID that can be reverted with `cast rpc --rpc-url "${FORGE_RPC_URL}" evm_revert <snapshot_id>`.

## Mainnet deployment

This section describes how to deploy a new `CoveredMetavault` to Ethereum mainnet.

### Prerequisites

#### Create deployer keystore

Ensure a keystore file exists at `keystore/deployer`. Create one using `cast`:

```shell
mkdir -p keystore
cast wallet import --keystore-dir keystore deployer --interactive
```

This prompts for your private key and a password to encrypt it.

#### Set environment variables

Configure environment variables according to [`.envrc.sample`](.envrc.sample).

#### Create deployment configuration

Create a TOML configuration file in `script/config/`. See [`script/config/morpho-smokehouse-usdc.toml`](script/config/morpho-smokehouse-usdc.toml) for an example:

```toml
[mainnet]
endpoint_url = "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"

[mainnet.address]
wrapped_vault = "0x..."          # ERC-4626 vault to wrap
keeper = "${MAINNET_KEEPER}"
manager = "${MAINNET_MANAGER}"
guardian = "${MAINNET_GUARDIAN}"
owner = "${MAINNET_OWNER}"
premium_collector = "${MAINNET_PREMIUM_COLLECTOR}"

[mainnet.uint]
premium_rate_bps = 100           # Initial premium rate (1% = 100 bps)
max_premium_rate_bps = 500       # Maximum premium rate (5% = 500 bps)
minimum_request_assets = 1000000 # Minimum deposit/redeem request (in asset decimals)
```

#### Export configuration path

Point `CONFIG_PATH` to your configuration file:

```shell
export CONFIG_PATH="script/config/morpho-smokehouse-usdc.toml"
```

### Deployment steps

#### Dry run (simulation)

Always run a dry run first to verify the deployment configuration:

```shell
bun run deploy:mainnet:dry-run
```

This simulates the deployment against a forked mainnet without broadcasting transactions. The script:
- Loads and validates the configuration
- Deploys the metavault proxy and implementation to the fork
- Verifies all roles and parameters are set correctly
- Logs deployment details

Review the output carefully before proceeding with the live deployment.

#### Live deployment

Once the dry run succeeds, deploy to mainnet:

```shell
bun run deploy:mainnet
```

You will be prompted for the keystore password. The script:
- Deploys the UUPS proxy and implementation contracts
- Grants `MANAGER_ROLE`, `GUARDIAN_ROLE`, and `KEEPER_ROLE` to the configured addresses
- Transfers ownership to the configured owner (if different from deployer)
- Logs the deployed proxy and implementation addresses

## Usage

### Build
```shell
forge build
```

### Test
Run the full suite with:
```shell
bun run test
# or run specific test
forge test --match-test <test_name>
```

### Format
```shell
forge fmt
```

### Gas Snapshots
```shell
forge snapshot
```

### Help
```shell
forge --help
anvil --help
cast --help
```
