# GrowFi — Claude Code guide

Permissionless RegenFi protocol: farmers/cooperatives tokenise a future harvest as $CAMPAIGN, stakers earn $YIELD, at harvest holders redeem $YIELD for physical product (Merkle proof) or pro-rata USDC.

## Contract suite (per-campaign proxies + protocol implementations)

All 5 per-campaign contracts are `Initializable` and deployed as `TransparentUpgradeableProxy` (ERC-1967). Each campaign has its own 5-proxy set, whose `ProxyAdmin` is owned by the campaign's **producer** — producer has full unilateral upgrade authority over their campaign (bug fixes, features, even malicious rewrites). The `CampaignFactory` itself is also behind a TransparentUpgradeableProxy, admin = factory owner.

| Contract | Role |
|---|---|
| `Campaign` | Funding escrow, sales, buyback-on-failure, sell-back queue, state machine (Funding → Active → {Buyback, Ended}) |
| `CampaignToken` | ERC20Votes, mint/burn gated to Campaign (+ StakingVault for penalty burns) |
| `StakingVault` | Stake $CAMPAIGN, earn $YIELD via Synthetix accumulator; linear early-unstake penalty; per-season accrual tracking |
| `YieldToken` | ERC20, mint by Vault, burn by Vault + HarvestManager |
| `HarvestManager` | Producer reports harvest → Merkle proof redemption for product OR pro-rata USDC redemption with partial deposits |

`CampaignFactory.createCampaign` deploys 5 `TransparentUpgradeableProxy`, each inline-initialized in dependency order (Campaign → CampaignToken → StakingVault → HarvestManager → YieldToken), then wires cross-references via `onlyFactory` setters guarded by `AlreadySet`. Because OZ 5.6+ mandates non-empty `initData` for proxies, initialize calldata is embedded in each proxy constructor.

## Trust model

- **Permissionless factory**: `createCampaign` is NOT `onlyOwner`. Anyone can launch; `require(params.producer == msg.sender)` enforces caller = producer.
- **Producer** (per campaign): owns `ProxyAdmin` of their 5 proxies → can upgrade any of their campaign's contracts at any time, no timelock. Also whitelists payment tokens, runs season lifecycle, reports harvest, deposits USDC.
- **Factory owner** (`Ownable2StepUpgradeable`): controls `protocolFeeRecipient` (for future campaigns), implementation addresses `setXxxImpl` (for future campaigns' defaults), emergency `pauseCampaign / unpauseCampaign`, and can upgrade the factory itself. **Cannot upgrade existing campaigns' contracts** — each campaign is producer-sovereign.
- **Holders / stakers**: must trust the campaign's producer not to rewrite the contracts maliciously. No protocol-level timelock or freeze — fully up to the producer's credibility. If a producer wants to make their campaign trustworthy, they should transfer their `ProxyAdmin` ownership to `address(0)` post-launch (renounceOwnership on the ProxyAdmin) or to a timelock/multisig.

## Critical invariants (asserted by `test/invariant/Invariants.t.sol`)

1. `stakingVault.totalStaked() == campaignToken.balanceOf(stakingVault)`
2. `sum(pendingSellBack[users]) == getSellBackQueueDepth()`
3. `currentSupply - totalSupply == ghost_totalBurned` (penalties/buyback)
4. `openSellBackCount[user] ≤ MAX_OPEN_SELLBACK_ORDERS_PER_USER` (50)
5. `yieldToken.totalSupply() ≤ Σ season.totalYieldOwed` (with O(positions) floor drift tolerance)

Invariant config: `runs = 256, depth = 128, fail_on_revert = false` → ~33k random sequences per invariant.

## Gotchas (audit-era learnings + upgradeable refactor)

- **Initializable pattern**: all 5 core contracts + factory are `Initializable` with `_disableInitializers()` in constructor. You cannot `new Campaign()` and use it directly — it must be deployed behind a proxy and initialized. Unit tests use `TransparentUpgradeableProxy` + `abi.encodeCall(Contract.initialize, ...)` to obtain a usable instance.
- **Deploy flow**: `test/helpers/Deployer.sol::deployProtocol()` deploys 5 core impls + factory impl + factory proxy. Every test's `setUp()` calls this helper.
- **No `ReentrancyGuardUpgradeable`**: OZ 5.6 dropped it. All contracts use the regular stateless `ReentrancyGuard` (namespaced-storage-slot variant), which is safe with clones/proxies without init.
- `depositUSDC(amount)` always splits **98% → pool, 2% → feeRecipient** on every deposit. Producer sizes the gross via `HarvestManager.remainingDepositGross(seasonId)`.
- Oracle-mode payment tokens must have `decimals() ≤ 18` (enforced at `addAcceptedToken`). `TokenConfig.paymentDecimals` is cached; pricing math scales by `10^(18 - paymentDecimals)`.
- On L2, the factory's `initialize` MUST pass the Chainlink sequencer-uptime feed. `address(0)` on L1/testnet. Feed addresses:
  - Arbitrum One: `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
  - Base Mainnet: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
- `HarvestManager.reportHarvest` reads `stakingVault.seasonTotalYieldOwed(seasonId)` — do NOT revert to `yieldToken.totalSupply()`; late claims would oversubscribe.
- `StakingVault.unstake` is intentionally NOT `whenNotPaused` — principal exit must always remain available. Only `stake/restake/claimYield` pause.
- `Campaign.buyback` is intentionally NOT `whenNotPaused` — emergency refund path for failed campaigns.
- **Never use `yieldToken.totalSupply()` as a harvest denominator.** Always `stakingVault.seasonTotalYieldOwed(id)`.

## Public views for UI / indexers

- `Campaign.previewBuy(token, paymentAmount) → (tokensOut, effectivePayment, oraclePrice)` — handles maxCap crop + oracle decimals. Does NOT simulate sellback queue fills (fills are supply-neutral).
- `Campaign.getPrice(token, campaignAmount)` — inverse: how much payment for N $CAMPAIGN.
- `HarvestManager.remainingDepositGross(seasonId)` — gross USDC producer must still send to fully cover `usdcOwed`, already factoring the 98/2 fee split.
- `StakingVault.seasonTotalYieldOwed(seasonId)` — canonical per-season yield snapshot (accrued minus forfeits).
- `Campaign.getSellBackQueueDepth()` — total $CAMPAIGN currently queued for sell-back.
- `CampaignFactory.minSeasonDuration()` — floor enforced by `createCampaign`. Settable by factory owner via `setMinSeasonDuration(uint256)`. Default 30 days on fresh deployments. Testnet relaxes to 3600 (1h) to allow fast integration smokes; mainnet keeps 30 days minimum.

## Dev commands

```bash
forge build                                       # compile (solc 0.8.24, via_ir)
forge test --no-match-path "test/fork/*"          # 123 local tests, ~15s
forge test --match-path "test/invariant/*"        # 11 invariants, ~7 min at 256×128
forge test --match-path "test/fork/*"              # needs RPC; skips gracefully
forge test --match-contract AuditFixesTest -vv    # audit regression suite
forge snapshot                                     # gas baseline
```

## Conventions

- Tests use `Deployer.deployProtocol(owner, feeRecipient, usdc, seqFeed)` in `setUp()` instead of `new CampaignFactory(...)`. This returns an already-initialized factory proxy.
- Tests use `vm.prank(producer)` before every `factory.createCampaign(...)` call because of the permissionless-model producer check. If you add a new test suite, remember this or setUp reverts with `"producer must be caller"`.
- Upgradeable contracts MUST keep storage layout stable across upgrades. When adding fields, append at the end or use a dedicated `__gap` array. Don't re-order or change existing field types.
- Custom errors preferred over string reverts on setters / validation paths.
- Never use `_paymentToTokens` (removed) — it duplicated `_calculateTokensOut` with drift risk. Use the queue-return pattern instead.
- New numerical invariants go into `Invariants.t.sol`, not individual test files, so they benefit from the full 33k-sequence fuzz.

## Upgrade path

The factory is the only upgradeable piece (per-campaign proxies are producer-administered, see Trust Model). Adding state to the factory requires:

1. Append new storage fields AT THE END of the contract (never re-order existing ones).
2. Add an `external reinitializer(N)` function named `initializeV{N}()` that seeds the new fields.
3. Deploy the new impl; call `ProxyAdmin.upgradeAndCall(proxy, newImpl, abi.encodeCall(CampaignFactory.initializeV{N}, ()))`.

Example reference: `script/UpgradeFactoryV2.s.sol` (adds `minSeasonDuration`, reads `ProxyAdmin` from the ERC-1967 admin slot, upgrades in one tx).

## Scripts reference

- `script/Deploy.s.sol` — mainnet/arbitrum full deploy (5 impls + factory impl + proxy).
- `script/DeployTestnet.s.sol` — testnet variant that additionally deploys MockUSDC and seeds the deployer with 1M mUSDC.
- `script/UpgradeFactoryV2.s.sol` — example factory upgrade path.
- `script/SmokeTest.s.sol` — live-chain happy-path check (createCampaign + addAcceptedToken + buy, asserts mint math).
- `script/SmokeTest1h.s.sol` — full lifecycle bootstrap with 1h season; stakes, ready for endSeason + harvest after time elapses.

## Deployments

See `CONTRACTS.md` for current Base Sepolia addresses (factory proxy, impls, ProxyAdmin, smoke campaigns, frontend env vars).

## Audit history

See commit `614226f` for the comprehensive audit-fix batch (H-01 through L-04, 13 findings). Regression tests live in `test/AuditFixes.t.sol` — one section per finding, labelled with the finding ID.

---

## Platform (web app, backend, subgraph)

Separate from the contracts, the `platform/` directory contains the user-facing stack. Added in commit `d6bcaaf`.

```
platform/
├── frontend/   Next.js 15 App Router — wallet + UI
├── backend/    Fastify — DO Spaces upload (port 4001)
└── subgraph/   Goldsky-deployed indexer
```

### Frontend (`platform/frontend/`)

- **Stack**: Next.js 15, RainbowKit v2, wagmi v2, viem, Tailwind 4, next-intl.
- **Chains**: Base Sepolia (default, chain 84532), Base Mainnet. Live testnet deployment addresses in `CONTRACTS.md`.
- **i18n**: EN / IT / ES / FR. Provider in `src/i18n/LocaleProvider.tsx` — browser auto-detect + `localStorage["growfi:locale"]` persistence. Messages in `src/messages/<locale>.json`.
- **Pages**:
  - `/` — Discovery, falls back to mock data when factory address unset.
  - `/create` — 4-step form. Three-stage deploy flow: (1) upload image + metadata JSON to DO Spaces via backend, (2) `factory.createCampaign` (producer = `msg.sender`), (3) parse the `CampaignCreated` log → call `registry.setMetadata(newCampaign, metadataUrl)` to link the JSON on-chain. Stage 3 is best-effort: if the registry tx fails, the deploy is still reported as successful (the subgraph simply won't have `metadataURI` for that campaign until the producer retries).
  - `/campaign/[address]` — Invest / Stake / Harvest / Info tabs. Hero (title, image, location, breadcrumb) resolves from `useSubgraphCampaign` + `useCampaignMetadata`; Info tab renders the JSON description. `BuyPanel` reads `getAcceptedTokens` + `tokenConfigs` + ERC20 symbol/decimals/balance/allowance, then orchestrates approve → buy. `StakingPanel` reads user positions via `getPositions` + batched `positions`/`earned` calls (10s refetch), shows live unstake penalty %, orchestrates approve → stake and per-position claim/unstake/restake tx flows. `HarvestPanel` lists seasons via `useCampaignSeasons` subgraph query, reads each user's `claims(seasonId, user)` on `HarvestManager`, and drives the two-step USDC flow (`redeemUSDC` → `claimUSDC`) with live pro-rata entitlement math (`owed × deposited / totalOwed − alreadyClaimed`). Product-redemption UI is stubbed with a "coming soon" marker because it needs a Merkle-proof backend endpoint.
  - `/portfolio` — wallet-gated aggregate of the user's on-chain activity across all campaigns. Single `useUserPortfolio` subgraph query returns purchases, active positions, and claims in one round-trip; per-position `earned` + ERC20 balance are then read live. Summary bar computes total invested, staked, $YIELD claimed, and USDC claimable (pro-rata against current deposits). Linked from the header nav.
- **Env** (`.env.local`): `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_BACKEND_URL`, `NEXT_PUBLIC_CHAIN_ID`, `NEXT_PUBLIC_FACTORY_ADDRESS`, `NEXT_PUBLIC_USDC_ADDRESS`, `NEXT_PUBLIC_SUBGRAPH_URL`.
- **Contract glue**: ABIs extracted from `forge build` via `jq` → `src/contracts/abis/*.json`. Hooks in `src/contracts/hooks.ts`. Minimal ERC20 ABI in `src/contracts/erc20.ts`.

### Backend (`platform/backend/`)

Fastify on **port 4001** (4000 was taken locally). Uses `@aws-sdk/client-s3` against DigitalOcean Spaces (S3-compatible).

**Storage target** — team `turinglabs`, project `Rifai`, bucket `growfi-media` in region `fra1`:
- Endpoint: `https://fra1.digitaloceanspaces.com`
- Public URL base: `https://growfi-media.fra1.digitaloceanspaces.com/`
- CORS: `GET`/`HEAD` from any origin
- Objects uploaded with `ACL=public-read` + `CacheControl: public, max-age=31536000, immutable` for images, `max-age=60` for JSON metadata
- Keys: `campaigns/<nanoid12>.<ext>` for images, `metadata/<nanoid12>.json` for metadata

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | liveness |
| `POST /api/upload` | multipart image → returns `{ key, url, size, contentType, filename }` |
| `POST /api/metadata` | JSON body `{ name, description, location, productType, imageUrl? }` → returns `{ key, url, metadata }` |

Env: `PORT`, `HOST`, `DO_SPACES_REGION`, `DO_SPACES_BUCKET`, `DO_SPACES_ENDPOINT`, `DO_SPACES_PUBLIC_BASE`, `DO_SPACES_KEY`, `DO_SPACES_SECRET`. Rotate keys with `doctl spaces keys create/delete`.

File constraints (5 MB, `image/{jpeg,png,webp,avif,gif}`) enforced in-route.

### Subgraph (`platform/subgraph/`)

Live on Goldsky — **team: turinglabs · project: growfi · chain: base-sepolia**. Current version: `growfi/1.1.0`, tagged as `prod`.

Indexed contracts (see `CONTRACTS.md` for authoritative deploy refs):
- `CampaignFactory` @ `0x3fA41528a22645Bef478E9eBae83981C02e98f74` from block `40322865`
- `CampaignRegistry` @ `0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e` from block `40331554`

Endpoints:
- **Prod tag**: `https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn`
- **Pinned version**: replace `prod` with the semver (e.g. `1.1.0`). Useful during schema migrations — older frontends can stay on an older version while the new one is tested.

Frontend client: `platform/frontend/src/lib/subgraph.ts` — minimal fetch+React Query wrapper exposing `useSubgraphCampaigns`, `useSubgraphCampaign(id)`, `useSubgraphMeta()`. Off-chain metadata JSON (pointed to by `Campaign.metadataURI`) is fetched by `platform/frontend/src/lib/metadata.ts::useCampaignMetadata(uri, version)` — queryKey includes `version` so an on-chain URI rotation invalidates cleanly.

Schema + handlers:
- `schema.graphql` — 11 entities: `Campaign`, `AcceptedToken`, `Purchase`, `SellBackOrder`, `Position`, `Season`, `Claim`, `YieldRateSnapshot`, `User`, `GlobalStats`, `ContractIndex`. The `Campaign` entity carries `metadataURI` + `metadataVersion` populated by the `CampaignRegistry` handler.
- **`ContractIndex`** maps StakingVault / HarvestManager addresses → owning `Campaign`. Populated in `src/factory.ts` when `CampaignCreated` fires, then read in `staking.ts` and `harvest.ts` to avoid expensive contract calls.
- 23 event handlers across `factory.ts`, `campaign.ts`, `staking.ts`, `harvest.ts`, `registry.ts`. No handler for `Initialized`/`Paused`/`Unpaused`/`OwnershipTransferred` (OZ stdlib events). No handler for `ProtocolFeeTargeted`/`ProtocolFeeTransferred` (replaced the old `ProtocolFeeCollected` — holder pool is derived from `HarvestReported` directly).
- **Dynamic templates**: `Campaign`, `StakingVault`, `HarvestManager` are all spawned via `Template.create()` inside the factory handler — this is why `startBlock` in `subgraph.yaml` must be the factory deploy block. `CampaignRegistry` is a static data source (single global contract).

Deploy:
```bash
cd platform/subgraph
npm run prepare              # codegen + build
npm run goldsky:login
npm run deploy:goldsky:prod  # tags as prod
```
Full guide: `platform/subgraph/DEPLOY.md`.

### Platform gotchas

- **Factory is live** on Base Sepolia at `0x3fA41528a22645Bef478E9eBae83981C02e98f74`. Discovery reads from the Goldsky subgraph; falls back to mock cards only when the indexer returns 0 campaigns. All write paths go to the real factory.
- **WalletConnect project ID** is live and committed to `.env.local` (not secret, just a rate-limit identifier). Don't commit `DO_SPACES_KEY` / `DO_SPACES_SECRET` — both `platform/backend/.gitignore` and root `.gitignore` exclude `.env`.
- **Chain name ↔ id alignment**: frontend uses `NEXT_PUBLIC_CHAIN_ID=84532`, subgraph uses `network: base-sepolia`. Both point at the same chain — keep in sync if you ever target a different network.
- **Subgraph `startBlock`** — already set to `40322865` (factory impl deploy block). Never set to 0 on mainnet/testnet; scanning from genesis wastes hours.
- **After re-deploying contracts**, re-extract ABIs with `jq '.abi' out/<Contract>.sol/<Contract>.json > platform/{subgraph,frontend}/...` and re-run `npm run prepare` in the subgraph. Stale ABIs cause `Event signature mismatch` at indexing time.
- **Permissionless `createCampaign`** means `onlyOwner` was removed; the require `params.producer == msg.sender` is what enforces proper attribution. Tests `vm.prank(producer)` before every factory call.
