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

**Standalone, single-instance registries** (not per-campaign, not upgradeable, see `CONTRACTS.md` for live addresses):
- `CampaignRegistry` — `(campaign => metadataURI)` + monotonic version. Producer-only write, gated by `factory.isCampaign`. Emits `MetadataSet`.
- `ProducerRegistry` — `(producer => profileURI)` + monotonic version. Anyone writes their own row (keys on `msg.sender`). Emits `ProfileUpdated`.

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

Invariant config: `runs = 256, depth = 128, fail_on_revert = false` → ~33k random sequences per invariant. GitHub Actions sets `FOUNDRY_PROFILE=ci`, which drops invariants to `64×48` and fuzz to `128` runs (~3min job vs ~25min) — local dev stays on the full profile.

## Gotchas (audit-era learnings + upgradeable refactor)

- **Initializable pattern**: all 5 core contracts + factory are `Initializable` with `_disableInitializers()` in constructor. You cannot `new Campaign()` and use it directly — it must be deployed behind a proxy and initialized. Unit tests use `TransparentUpgradeableProxy` + `abi.encodeCall(Contract.initialize, ...)` to obtain a usable instance.
- **Deploy flow**: `test/helpers/Deployer.sol::deployProtocol()` deploys 5 core impls + factory impl + factory proxy. Every test's `setUp()` calls this helper.
- **No `ReentrancyGuardUpgradeable`**: OZ 5.6 dropped it. All contracts use the regular stateless `ReentrancyGuard` (namespaced-storage-slot variant), which is safe with clones/proxies without init.
- `depositUSDC(amount)` always splits **98% → pool, 2% → feeRecipient** on every deposit. Producer sizes the gross via `HarvestManager.remainingDepositGross(seasonId)`.
- Oracle-mode payment tokens must have `decimals() ≤ 18` (enforced at `addAcceptedToken`). `TokenConfig.paymentDecimals` is cached; pricing math scales by `10^(18 - paymentDecimals)`.
- **Accepted payment tokens MUST behave like a standard ERC20**: no fee-on-transfer, no rebasing, no ERC777 hooks. The producer's accepted-token allowlist is permissionless per-campaign, so a careless producer could add a fee-on-transfer token; `Campaign.buy` then records the DECLARED `paymentAmount` in `purchases[user][token]` while the contract actually receives less, which makes the last buyback refund revert with `ERC20InsufficientBalance` if the campaign fails. Regression: `test/PoolSecurity.t.sol::test_feeOnTransfer_buybackShortfallForLastUser`. ERC777 reentrancy is safe because `Campaign` does not register an ERC1820 recipient hook, but fee-on-transfer is not code-mitigated — it's a producer-responsibility footgun. Frontend should filter the `KNOWN_TOKENS` list to standard ERC20s only.
- On L2, the factory's `initialize` MUST pass the Chainlink sequencer-uptime feed. `address(0)` on L1/testnet. Feed addresses:
  - Arbitrum One: `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`
  - Base Mainnet: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
- `HarvestManager.reportHarvest` reads `stakingVault.seasonTotalYieldOwed(seasonId)` — do NOT revert to `yieldToken.totalSupply()`; late claims would oversubscribe.
- `StakingVault.unstake` is intentionally NOT `whenNotPaused` — principal exit must always remain available. Only `stake/restake/claimYield` pause.
- `Campaign.buyback` is intentionally NOT `whenNotPaused` — emergency refund path for failed campaigns.
- **Never use `yieldToken.totalSupply()` as a harvest denominator.** Always `stakingVault.seasonTotalYieldOwed(id)`.
- **USDC redeem is a 2-phase flow.** Each phase emits its own event, and the names are semantically correct:
  - `redeemUSDC(seasonId, yieldAmount)` — BURNS $YIELD, registers a pending claim. Emits `USDCCommitted(user, seasonId, yieldBurned, usdcAmount)`. No USDC moves here.
  - `depositUSDC(seasonId, amount)` — producer funds the pool (98% → holders, 2% → feeRecipient). Emits `USDCDeposited`.
  - `claimUSDC(seasonId)` — holder pulls their pro-rata USDC. Emits `USDCRedeemed(user, seasonId, amount)` — this is the ONLY event where USDC actually transfers.
  - NB: the pre-2026-04-18 contract had these names swapped (old `USDCRedeemed` fired at commit time, old `USDCClaimed` fired at transfer). Never revert to the old names. See `docs/REDEEM_2STEP.md` for the full UX spec.
- **Sell-back queue reachable at maxCap.** `Campaign.buy()` no longer reverts `MaxCapReached` the moment `currentSupply == maxCap`; it clamps `tokensOut` to `mintableRoom + queueTokens` and lets a new buyer consume the queue even at cap (fills are burn+mint → supply-neutral). Revert only when BOTH mintable room and queue are empty. Regression: `test/SellBackAtMaxCap.t.sol`. Pre-2026-04-20 deploys had the eager revert and the queue was unreachable once full.
- **Producer parameter setters.** Three `onlyProducer` setters on Campaign.sol — `setFundingDeadline(uint256)`, `setMinCap(uint256)`, `setMaxCap(uint256)` — let the producer retune caps/deadline without an impl-redeploy. Guard-rails: deadline can only be extended; minCap must stay `> currentSupply` and `≤ maxCap` (Funding-only); maxCap must stay `≥ currentSupply + _queueTotalTokens()` (Funding or Active). Emits `FundingDeadlineUpdated` / `MinCapUpdated` / `MaxCapUpdated`, indexed by the subgraph. Regression: `test/ParamUpdates.t.sol`. Trust note: producer already owns ProxyAdmin so this adds no new trust surface; it just skips the upgrade dance.

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
- `script/UpgradeFactoryV2.s.sol` — example factory upgrade (adds `minSeasonDuration`, uses `initializeV2` reinitializer).
- `script/UpgradeHarvestManager.s.sol` — deploys a new HarvestManager impl, points factory at it for future campaigns, and walks through every HM proxy listed in env (OLIVE/FAST/SMOKE) upgrading each via its own ProxyAdmin. Template for per-campaign impl upgrades.
- `script/SmokeTest.s.sol` — single-buy happy-path assertion (fixed-rate mint math).
- `script/SmokeTest1h.s.sol` — single-actor lifecycle bootstrap with 1h season; stakes, ready for endSeason + harvest after time elapses.
- `script/OliveSetup.s.sol` — **2-actor** lifecycle bootstrap (producer + 2nd staker, 30-min season). Producer buys to auto-activate + startSeason + stake; mints mUSDC to Bob; Bob buys + stakes.
- `script/OliveFinish.s.sol` — Phase 2a of the 2-actor flow (endSeason, both claimYield, reportHarvest with single-leaf Merkle root, alice redeemUSDC, bob redeemProduct). Stops before depositUSDC; pair with `finish-olive.sh` for the tail.
- `script/finish-olive.sh` — wraps `OliveFinish.s.sol` then executes `depositUSDC` + `claimUSDC` via cast reading live `remainingDepositGross`. Avoids forge-script double-simulation drift.
- `script/finish-single-actor.sh` — pure-cast variant for single-actor campaigns (FAST-style). One cast per step; no forge simulation involved.

## Deployments

See `CONTRACTS.md` for current Base Sepolia addresses (factory proxy, impls, ProxyAdmin, smoke campaigns, frontend env vars). See `DEPLOY.md` for the DigitalOcean App Platform runbook (frontend + backend) — `.do/app.yaml` spec, per-service Dockerfiles, CLI-only secret injection via `doctl apps update` + `jq` spec patching, and the auto-deploy-on-push flow against `main`. Live at `https://growfi-test-m9s8u.ondigitalocean.app` (app id `9e4019f4-8dbc-4170-8546-ce7d8579e3a4`, team `turinglabs`). **Path-based ingress gotcha**: the backend rule needs `preserve_path_prefix: true` — by default DO App Platform strips the match prefix before forwarding, so a rule matching `/api` would deliver `/upload` to the backend while our routes are `/api/upload` → every endpoint 404s. The flag is documented inline in `.do/app.yaml`.

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
- **Tx lifecycle** — every write-contract is wrapped in an imperative `sig → chain → success/error` flow using `waitForTransactionReceipt` from `@wagmi/core` (NOT the `useWaitForTransactionReceipt` hook — that caused receipt-hash race bugs where the "acquisto confermato" banner showed an approval hash). The exported wagmi `config` from `app/providers.tsx` is passed to `waitForTransactionReceipt`. User-rejected errors are silently discarded; on-chain reverts surface as a red banner per panel.
- **Pages**:
  - `/` — Discovery reads all campaigns from the subgraph. No mock fallback; if subgraph returns 0, shows a "no campaigns yet" empty state with a CTA to create one.
  - `/create` — 4-step form with the full imperative deploy flow: upload image + metadata JSON → `factory.createCampaign` (producer = msg.sender) → `registry.setMetadata(newCampaign, metadataUrl)` → for each accepted token, `addAcceptedToken(...)`. All stages mandatory now (no more silent best-effort) — any failure halts and surfaces the error with retry. Step 1 collects campaign name + yield name/symbol so the producer customizes `$CAMP → earn $OIL` relationships. Step 3 picks from a curated `KNOWN_TOKENS` list (mUSDC active on Sepolia; USDC/DAI/USDT/WETH/cbBTC disabled preview for mainnet). Stablecoin entries (`stableUsd: true`) hide the "Prezzo (per 1 $CAMP)" input and derive `fixedRate` straight from `pricePerToken` (scaled to the stablecoin's decimals) so the producer enters the USD price once.
  - `/campaign/[address]` — 5 tabs. The active tab mirrors the `?tab=` query param (`invest` | `stake` | `harvest` | `info` | `manage`), so deep links like `ProducerAggregateDashboard`'s `?tab=manage` land directly on the right panel. Local state stays in sync via a `useSearchParams` effect.
    - **Invest** — `FundingProgressCard` with soft-cap tick marker + days-left + progress. `BuyPanel` reads `getAcceptedTokens` + `tokenConfigs` + ERC20 symbol/decimals/balance/allowance, clamps `tokensOutEstimate` to `maxCap - currentSupply + queueTokens` (mirrors the v2 contract's post-fix clamp so queue consumption at cap is offered), pre-flight checks `MaxCapReached`, supports a testnet-only "Mint 10,000 mUSDC" button. Also renders `SellBackPanel` (Active state), `RefundPanel` (Buyback state: per-token `buyback(token)` refund flow), and below them `InvestorList` — a social-recognition widget that folds `Purchase` events by buyer, batch-resolves ProducerRegistry profiles (name + avatar + verified check) with a shortened-address fallback for anonymous wallets, shows % of supply + tx count per row, and deep-links each row to `/producer/<address>`. Above the panels, `TriggerBuybackCta` shows on Funding past deadline below minCap. Right-column `StatsCard` replaces the flat 1x/3x/5x bar with `YieldRateCurve`: inline SVG chart of `rate = 5 - 4 * (totalStaked / maxSupply)` with gridlines, Y-axis labels (5x/3x/1x), gradient fill, dashed drop-line, and a pulsing marker at the current `totalStaked%` (animated `r`+`opacity`, 2.4s loop) — pure SVG, zero charting deps. All fiat labels use `$` (the protocol is USD-anchored; `€` would require an FX feed we don't need). All uses the real `campaignToken.symbol()` — no more hardcoded `$CAMP`/`$CAMPAIGN`.
    - **Staking** — `StakingPanel` reads positions via `getPositions` + batched `positions`/`earned` (10s refetch), guards against `NoActiveSeason` (pre-flight check on `seasons[currentSeasonId].active`) and `TooManyPositions` (50/user cap). Live unstake-penalty %. Uses dynamic `yieldToken.symbol()` everywhere.
    - **Harvest** — `HarvestPanel` lists seasons including `UnreportedSeasonCard` (waiting-for-producer state) alongside reported ones. Reported seasons render `SeasonCard` + `UsdcClaimTimeline` (4-phase post-commit state machine: Committed → Producer deposit → Claimable → Fulfilled) with a shortfall banner when `usdcDeadline` passes under-funded. Dust tolerance `1e12` (18-dec internal scale) on `fulfilled`. Hides entirely when user has no YIELD + no claim + window closed.
    - **Info** — off-chain description + contract address + deploy block.
    - **Manage** (producer-only) — `ProducerManagePanel` with 5 sections: **LifecycleSection** (Activate/StartSeason/EndSeason/EndCampaign buttons gated by state + active-season flag; Activate disables itself with an actionable hint showing `currentSupply / minCap (%)` when below the soft cap so the producer never sends a tx that will revert `MinCapNotReached`; End Season becomes primary when `seasonDuration` elapsed); **ReportHarvestCard** per ended-unreported season (backend snapshot + merkle gen + `reportHarvest` imperative flow); **ParametersEditor** (three separate-tx rows for the producer-only setters: `setFundingDeadline` date picker — Funding-only, extend-only; `setMinCap` input — Funding-only, must stay > currentSupply; `setMaxCap` input — Funding or Active, must stay ≥ currentSupply + sellback queue; each row reads the live value from chain, disables itself outside the allowed state with an actionable hint, and toasts success/failure); **AcceptedTokensManager** (list current with Remove, add new from KNOWN_TOKENS); **ObligationCard** per reported season (progress bar, `remainingDepositGross` view, approve+`depositUSDC` flow, shortfall banner when deadline passes, "reported-no-commits" early-return that surfaces the just-committed numbers — total harvest value USD, product units, merkle root, claim window, deposit deadline — so the producer can sanity-check the report; applies `DUST_18 = 1e12` tolerance on `fullyDeposited` to absorb the 6→18 decimal floor of the 98/2 fee split). All inline raw-revert banners were dropped — errors come through the toast system only, which filters `user rejected` silently and decodes viem errors into user-friendly messages.

    Plus the page hosts two banners above the tabs: `ActivateCtaBanner` (producer-only, highlights activation when minCap reached in Funding state) and `LinkMetadataBanner` (producer-only, when `registry.metadataURI === ""` — recovery UI that re-uploads metadata JSON and signs `setMetadata`, polling the subgraph until the new URI is visible).
  - `/portfolio` — wallet-gated aggregate of the user's on-chain activity across all campaigns. Single `useUserPortfolio` subgraph query returns purchases, active positions, and claims in one round-trip; per-position `earned` + ERC20 balance are read live. USDC claims in the list use the same 4-phase timeline/badge pattern as HarvestPanel so the holder sees consistent status.
  - `/producer/[address]` — public producer profile page. When the connected wallet IS the producer, a `ProducerAggregateDashboard` renders at the top: 4 KPIs (campaigns, total raised, USDC still owed, pending reports) + deep-link chips to the specific campaigns that need action (`?tab=manage` on each). Edit form flow: upload via backend → `uploadProducerProfile` → `ProducerRegistry.setProfile` → poll subgraph until `version` bumps, then close and invalidate the parent query.
- **Key components**: `Spinner` (inline spinner for tx states), `CampaignImage` (branded green-gradient fallback with GrowFi logo when no cover image), `Header` (unified pill buttons + Profile shortcut when wallet connected), `LanguageSwitcher`, `Toast` / `ToastProvider` (bottom-right, auto-dismiss, `useTxNotify()` helper wraps push + silences user-rejections + injects explorer links), `InvestorList`, `YieldRateCurve`, `RefreshButton`.
- **Subgraph hooks of note**: `useCampaignInvestors(address)` folds Purchase events per buyer for the InvestorList widget; `useBatchProducerProfiles(addresses[])` resolves wallet → ProducerRegistry profile (name + avatar) in one GraphQL round-trip with a `force-cache` fetch of the off-chain JSON; `useProducerAggregate(address)` powers the producer dashboard KPIs.
- **Known tokens catalog**: `src/contracts/tokens.ts` — curated `KNOWN_TOKENS` list with per-chain addresses and Chainlink feeds. Only `mUSDC` is `enabled: true` on Sepolia; others are `enabled: false` preview for mainnet. Used by `/create` step 3, `ProducerManagePanel` → AcceptedTokensManager.
- **Env** (`.env.local`): `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_BACKEND_URL`, `NEXT_PUBLIC_CHAIN_ID`, `NEXT_PUBLIC_FACTORY_ADDRESS`, `NEXT_PUBLIC_USDC_ADDRESS`, `NEXT_PUBLIC_SUBGRAPH_URL`.
- **Contract glue**: ABIs extracted from `forge build` via `jq` → `src/contracts/abis/*.json`. Hooks in `src/contracts/hooks.ts`. Minimal ERC20 ABI in `src/contracts/erc20.ts`.
- **Prod build**: `next.config.ts` ships with `output: "standalone"` so the Docker image copies only `.next/standalone/server.js` plus static assets (~150 MB), not the full `node_modules`. The multi-stage `platform/frontend/Dockerfile` accepts every `NEXT_PUBLIC_*` as a build ARG — miss one and the build fails loudly. `.do/app.yaml` feeds the current Base Sepolia addresses at BUILD_TIME scope; secret public vars (only `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`) live in the dashboard. Root `DEPLOY.md` is the runbook.

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
| `POST /api/producer` | JSON body `{ name, bio, avatar?, cover?, website?, location? }` → returns `{ key, url, profile }` (used by `/producer/[address]` edit flow before `ProducerRegistry.setProfile`) |
| `GET /api/snapshot/:campaign/:seasonId` | Returns `{ holders: [{user, yieldAmount}], totalYield, ... }` at season-close. Implemented in `src/snapshot.ts`: queries the subgraph for active positions at the season, then multicalls `earned(positionId)` on the StakingVault, merges with `Position.yieldClaimed` to get total per-user $YIELD. Feeds directly into `/api/merkle/generate`. Used by ProducerManagePanel's reportHarvest flow. |
| `POST /api/merkle/generate` | Body: `{ campaign, seasonId, totalProductUnits, holders: [{ user, yieldAmount }], minProductClaim? }`. Builds a Merkle tree with leaves `keccak256(abi.encodePacked(user, seasonId, productAmount))` and `sortPairs=true` (OZ `MerkleProof.verify`-compatible). Persists tree + all proofs at `merkle/<campaign>/<seasonId>.json` on DO Spaces. Returns `{ root, url, count }`. Root is what the producer passes to `HarvestManager.reportHarvest`. |
| `GET /api/merkle/:campaign/:seasonId/:user` | Reads the tree JSON from the public bucket and returns `{ user, productAmount, proof }` for that user — or 404 if they're not in the snapshot / below `minProductClaim`. |

Env: `PORT`, `HOST`, `DO_SPACES_REGION`, `DO_SPACES_BUCKET`, `DO_SPACES_ENDPOINT`, `DO_SPACES_PUBLIC_BASE`, `DO_SPACES_KEY`, `DO_SPACES_SECRET`. Rotate keys with `doctl spaces keys create/delete`.

File constraints (5 MB, `image/{jpeg,png,webp,avif,gif}`) enforced in-route.

### Subgraph (`platform/subgraph/`)

Live on Goldsky — **team: turinglabs · project: growfi · chain: base-sepolia**. Current version: `growfi/2.1.0`, tagged as `prod`.

Indexed contracts (see `CONTRACTS.md` for authoritative deploy refs):
- `CampaignFactory` @ `0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64` from block `40456524`
- `CampaignRegistry` @ `0x6cfC4b78131947721A2370B594Ed81BD758a1e17` from block `40456633`
- `ProducerRegistry` @ `0x2bbc8FE2626C7f83fDe22E4799E76B93Cc8b379e` from block `40457114`

Endpoints:
- **Prod tag**: `https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn`
- **Pinned version**: replace `prod` with the semver (e.g. `1.1.0`). Useful during schema migrations — older frontends can stay on an older version while the new one is tested.

Frontend client: `platform/frontend/src/lib/subgraph.ts` — minimal fetch+React Query wrapper exposing `useSubgraphCampaigns`, `useSubgraphCampaign(id)`, `useSubgraphMeta()`. Off-chain metadata JSON (pointed to by `Campaign.metadataURI`) is fetched by `platform/frontend/src/lib/metadata.ts::useCampaignMetadata(uri, version)` — queryKey includes `version` so an on-chain URI rotation invalidates cleanly.

Schema + handlers:
- `schema.graphql` — 12 entities: `Campaign`, `AcceptedToken`, `Purchase`, `SellBackOrder`, `Position`, `Season`, `Claim`, `YieldRateSnapshot`, `User`, `GlobalStats`, `ContractIndex`, `Producer`. The `Campaign` entity carries `metadataURI` + `metadataVersion` populated by the `CampaignRegistry` handler. The `Producer` entity (id = producer address) carries `profileURI` + `version` populated by the `ProducerRegistry` handler; it has no derived `campaigns` relation — frontend queries campaigns separately with `where: { producer: $addr }`.
- **`ContractIndex`** maps StakingVault / HarvestManager addresses → owning `Campaign`. Populated in `src/factory.ts` when `CampaignCreated` fires, then read in `staking.ts` and `harvest.ts` to avoid expensive contract calls.
- 26 event handlers across `factory.ts`, `campaign.ts`, `staking.ts`, `harvest.ts`, `registry.ts`, `producer.ts`. The new handlers `handleFundingDeadlineUpdated / handleMinCapUpdated / handleMaxCapUpdated` mutate the indexed `Campaign.fundingDeadline / minCap / maxCap` in-place so the discovery grid + detail page reflect producer parameter updates within a few seconds of each tx. No handler for `Initialized`/`Paused`/`Unpaused`/`OwnershipTransferred` (OZ stdlib events). No handler for `ProtocolFeeTargeted`/`ProtocolFeeTransferred` (replaced the old `ProtocolFeeCollected` — holder pool is derived from `HarvestReported` directly).
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

- **Factory is live** on Base Sepolia at `0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64` (see `CONTRACTS.md` for the v2 address set). Discovery reads exclusively from the Goldsky subgraph — no more mock fallback. Empty subgraph → empty state CTA.
- **Imperative tx flow everywhere** — never use `useWaitForTransactionReceipt` + useEffect for progress state (race-prone: a receipt from the previous tx can briefly match while a new tx is in flight and show wrong success). Always use `waitForTx(hash)` from `@/lib/waitForTx` inside the async handler — it wraps `waitForTransactionReceipt` with `confirmations: 2`, `timeout: 90s`, and a `minVisibleMs` floor (default 1200ms) so the "confirming on-chain…" state is visible even when the receipt is cached. Silence `user rejected/denied` errors; surface everything else. The shared `config` is exported from `src/app/providers.tsx`.
- **RPC fallback** — `providers.tsx` uses a viem `fallback` transport across `sepolia.base.org`, `base-sepolia-rpc.publicnode.com`, and `base-sepolia.blockpi.network` (each with 3 retries @ 500ms, 10s timeout). The primary public endpoint was returning "block not found" mid-call often enough to break `activateCampaign` simulations — a single-endpoint config is brittle.
- **Season struct index**. `StakingVault.Season` layout is `(startTime, endTime, totalYieldMinted, rewardPerTokenAtEnd, totalYieldOwed, active, existed)`. Read `active` as index `5`, NOT index `3` — the original frontend hit `[3]` and false-read `rewardPerTokenAtEnd` (uint256, usually 0n, coerces to `false`), so `hasActiveSeason` stayed `false` right after `startSeason`. Both `LifecycleSection` and `StakingPanel` now use the correct indices with typed tuples + inline layout comments.
- **Two-phase USDC redeem** (see `docs/REDEEM_2STEP.md`): `redeemUSDC` burns $YIELD and emits `USDCCommitted` (no USDC moves), `depositUSDC` funds the pool emitting `USDCDeposited`, `claimUSDC` pulls pro-rata USDC emitting `USDCRedeemed`. Frontend timeline and producer dashboard are aligned to these three events. Frontend ABI must carry the current names (old `USDCClaimed` is historical).
- **WalletConnect project ID** is live and committed to `.env.local` (not secret, just a rate-limit identifier). Don't commit `DO_SPACES_KEY` / `DO_SPACES_SECRET` — both `platform/backend/.gitignore` and root `.gitignore` exclude `.env`.
- **Chain name ↔ id alignment**: frontend uses `NEXT_PUBLIC_CHAIN_ID=84532`, subgraph uses `network: base-sepolia`. Both point at the same chain — keep in sync if you ever target a different network.
- **Subgraph `startBlock`** — already set to `40322865` (factory impl deploy block). Never set to 0 on mainnet/testnet; scanning from genesis wastes hours.
- **After re-deploying contracts**, re-extract ABIs with `jq '.abi' out/<Contract>.sol/<Contract>.json > platform/{subgraph,frontend}/...` and re-run `npm run prepare` in the subgraph. Stale ABIs cause `Event signature mismatch` at indexing time.
- **Permissionless `createCampaign`** means `onlyOwner` was removed; the require `params.producer == msg.sender` is what enforces proper attribution. Tests `vm.prank(producer)` before every factory call.
- **Checksumming** — `NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS` (and any other env-supplied address) must be EIP-55 checksum or lowercase — mixed case fails viem's validator with `Address … is invalid`. Run `cast to-check-sum-address 0x...` after any new deploy.

### Platform testing

Three layers, all runnable in CI:

| Layer | Command | Coverage |
|---|---|---|
| Contracts | `forge test --no-match-path "test/fork/*"` | ~123 unit + 1 full-lifecycle E2E (`test/E2E.t.sol::test_E2E_fullLifecycle`) + 10 pool-security PoCs (`test/PoolSecurity.t.sol`) covering reentrancy on every `nonReentrant` entry, cross-function reentry, cross-proxy reentry, and fee-on-transfer blast-radius. |
| Backend | `cd platform/backend && npm test` | 24 Node `node:test` cases: merkle packing + OZ-compatibility proof verification, and Fastify `inject()` integration for every route. Uses injected S3 / snapshot stubs — no network, no AWS. |
| Frontend | `cd platform/frontend && npm run build` | Type-safe build (Next.js + tsc). Manual UI smoke in Chrome for the post-harvest timeline. |

Testnet smoke (manual, needs 2 funded keys):
1. `forge script script/OliveSetup.s.sol --broadcast` — creates campaign, Alice buys + activates + stakes, mints mUSDC to Bob, Bob buys + stakes. Wait 30 min.
2. `forge script script/OliveFinish.s.sol --broadcast` — endSeason, both claimYield, reportHarvest (single-leaf Merkle), alice redeemUSDC, bob redeemProduct.
3. `./script/finish-olive.sh` — producer `depositUSDC` + alice `claimUSDC` via cast (avoids forge simulation drift on the 2-step flow).

All tx paths in the frontend now surface both toast notifications (success with explorer link / error with contract revert reason) AND panel-local error banners for in-context visibility.
