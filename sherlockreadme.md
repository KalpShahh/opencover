On what chains are the smart contracts going to be deployed?

Ethereum, Base, Arbitrum and Optimism.

If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of weird tokens you want to integrate?

A metavault wraps a single ERC-4626 vault, set at deployment. Vaults that issue non-standard ERC-20 shares are not supported with explicit onchain checks present for fee-on-transfer tokens. Rebasing and other "weird" token traits are not supported. We accept wrapped vault governance risks (e.g. fee changes, pausing or upgrades) and vaults are curated and assessed prior to deployment. The metavault is expected to only integrate with ERC4626 vaults whose shares behave as standard ERC20 tokens without any weird traits. Any weird traits are considered out of scope (except 6-18 decimals).

Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?

All roles (Owner, Manager, Keeper, Guardian) are trusted.

Owner has UUPS upgrade authority and can grant/revoke roles.
Manager-controlled premium rate is bounded by a per-vault max (set at deployment) which itself can't exceed the hardcoded 25% cap. minimumRequestAssets is configured to block dust requests and is set to a meaningful amount (>$1,000 or asset equivalent).
The keeper-controlled settle() call accepts an unbounded array of redemption request IDs and will revert on invalid/already-settled/duplicate IDs, so batching and ID validation/dedup are handled offchain. The optional expectedPendingAssets argument provides exact-match protection against deposit frontrunning.
The premium streaming compounding loop is bounded at MAX_PREMIUM_YEARS = 100 iterations to prevent gas DoS if the vault is inactive for extended periods.
No changes to hardcoded constants are planned.

Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?

No. We trust the governance of the wrapped ERC-4626 vaults. Vaults are selected after rigorous risk and technical assessment before metavault deployment.

Is the codebase expected to comply with any specific EIPs?

ERC-7540: Async deposit/redemption flows enable the keeper to manage coverage (must be in excess of settled vault TVL) and capacity + allows for epoch-based premium streaming. Operator delegation is omitted and all operations enforce controller == owner == msg.sender (no delegation) and receiver == controller (no redirection) to prevent griefing attacks. claimableRedeemRequest() returns the original settled amount (not remaining), integrators should use claimableRedeemShares() for actual claimable balance.

ERC-7575: Single-asset vault semantics for DeFi composability, ERC-4626 preview functions revert per ERC-7540.

EIP violations can be considered valid only if they qualify for Medium and High severity definitions.

Are there any off-chain mechanisms involved in the protocol (e.g., keeper bots, arbitrage bots, etc.)? We assume these mechanisms will not misbehave, delay, or go offline unless otherwise specified.

Yes, the keeper and associated settlement/cover management engines are operated by OpenCover. The keeper monitors onchain events and periodically settles to stream premium and process batches, enforcing redemption minimums and ensuring coverage matches vault TVL. The keeper is trusted to operate correctly and settle in a timely manner. Users have an onchain exit guarantee via settleMaturedRedemption() after 24 hours if the keeper stalls (unless contract is paused).

What properties/invariants do you want to hold even if breaking them has a low/unknown impact?

The smart contract uses assert statements for hard invariants (e.g. for pricing / epoch snapshot assumptions). A few of the most important invariants are:

totalAssets() <= totalSupply() i.e. the share price in terms of the asset is never > 1 (premium streaming only reduces assets, never increases shares).
Settled assets must always cover reserved redemptions.
Premium streaming can't overdraw settled assets.
If pending deposits are settled for an epoch, a non‑zero epoch snapshot must exist for that epoch.
Tracked asset accounting must remain internally consistent.
Please discuss any design choices you made.

Deposit requests are cancellable only while pending in the current epoch (by the user or keeper), redemption requests are cancellable only by the user until settled.
totalAssets() uses internally tracked assets rather than balanceOf() to prevent donation/inflation attacks. Direct transfers to the vault are ignored.
settle() is strict and may revert on invalid redemption IDs to prevent silent skipping. The redemption array length is unbounded onchain but implicitly gas-bounded and keeper manages batch sizing, frequency and correctness offchain.
Premium rate is bounded (per-vault cap + hard cap) but can change intra-epoch. Premium math is intentionally conservative (floors down), keeper settlement cadence is chosen so premium does not repeatedly floor to 0.
Guardian-controller pause is a full emergency stop of the vault's main state-changing operations prioritising control over guaranteed exits during incident response.
Rewards from underlying protocols (where applicable) are forwarded to depositors via Merkl.
Please provide links to previous audits (if any) and all the known issues or acceptable risks.

Nethermind Security (Dec 2025): https://github.com/NethermindEth/PublicAuditReports/blob/main/NM0674-FINAL_OPENCOVER.pdf

Please list any relevant protocol resources.

README.md contains technical and usage details.
The Gitbook (linked in README.md) covers product details, business context and integration documentation.
All public/external functions include comprehensive NatSpec documentation inline with the source code.
Additional audit information.

Focus areas include vault accounting correctness, rounding behaviour, technical & economic attack vectors (without privileged access) and scenarios where users could suffer material financial loss through manipulation or edge cases.
