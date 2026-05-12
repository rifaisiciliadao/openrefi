# GrowFi — Deployments

## Ethereum Sepolia (chain 11155111) — v4 module architecture + GROW system

**Deployed:** 2026-05-12 · **Deployer/owner:** `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33`

> First v4 deployment on an L1 testnet, ahead of the Ethereum mainnet
> target. Module-based Campaign architecture (host + delegatecall router
> + Sale/Collateral/Repayment modules) replaces the v3 monolith. GROW
> system (Token + Treasury + Minter + FeeSplitter + StakingPool) wired
> in a separate broadcast on top.
>
> Seed campaigns: Olive Sicily ($0.144/CT, 350k maxCap) +
> Vineyard of Etna ($0.10/CT, 500k maxCap). Both Active, tracked in
> the Treasury with `automationEnabled=true`.
>
> Subgraph: `growfi/4.0.1` on Goldsky (NOT tagged `prod` — `prod` still
> points at Base Sepolia v3.3).

### Core v4 (campaign factory + module impls + registries)

| Contract | Address | Notes |
|---|---|---|
| **CampaignFactory** (proxy) | [`0xa4DEd8Ab35e89bCAF1f7DFeb7aB2c1ED533b3f05`](https://sepolia.etherscan.io/address/0xa4DEd8Ab35e89bCAF1f7DFeb7aB2c1ED533b3f05) | v4 permissionless factory. `FUNDING_FEE_BPS=300`, `HARVEST_PROTOCOL_FEE_BPS=200`. Deploy block `10838711`. |
| CampaignFactory impl | [`0x3fA41528a22645Bef478E9eBae83981C02e98f74`](https://sepolia.etherscan.io/address/0x3fA41528a22645Bef478E9eBae83981C02e98f74) | |
| **Campaign host** impl | [`0x0DBE11aD9c2bf4126FE8D422e7374dE47600A2ca`](https://sepolia.etherscan.io/address/0x0DBE11aD9c2bf4126FE8D422e7374dE47600A2ca) | Delegatecall router, namespaced storage, module attach/detach/enabled lifecycle. |
| CampaignToken impl | [`0x81C4e22EC9198f2983217C483e4027cf49E940db`](https://sepolia.etherscan.io/address/0x81C4e22EC9198f2983217C483e4027cf49E940db) | |
| StakingVault impl | [`0x092Ed1e0845f6817e24316A730E98ec074e5F017`](https://sepolia.etherscan.io/address/0x092Ed1e0845f6817e24316A730E98ec074e5F017) | `forceUnstake` now mints accrued YIELD to owner (no forfeit) — producer-blessed exit path used by `RepaymentModule.redeem`. |
| YieldToken impl | [`0x8d434e38dd91D9b738f8803dbD18b815720BEDad`](https://sepolia.etherscan.io/address/0x8d434e38dd91D9b738f8803dbD18b815720BEDad) | |
| HarvestManager impl | [`0x38da3922d3Bc3281F57946618404F0E341777F68`](https://sepolia.etherscan.io/address/0x38da3922d3Bc3281F57946618404F0E341777F68) | |
| **SaleClassicModule** impl | [`0x17eb232C3D25c90794761B85ddad8e5E38f0ED8a`](https://sepolia.etherscan.io/address/0x17eb232C3D25c90794761B85ddad8e5E38f0ED8a) | Default auto-attached on every `createCampaign`. Buy/sellback/buyback/setMaxCap etc. |
| **CollateralModule** impl | [`0xF2EAb14F7288E7d4E611C44F2784dfF6394ec476`](https://sepolia.etherscan.io/address/0xF2EAb14F7288E7d4E611C44F2784dfF6394ec476) | Default auto-attached. `lockCollateral`, `depositUSDC`, `settleSeasonShortfall`. |
| **RepaymentModule** impl | [`0x90e6280684a9F00B5241912176F9F0dC5552698d`](https://sepolia.etherscan.io/address/0x90e6280684a9F00B5241912176F9F0dC5552698d) | Whitelisted but NOT default. Producer attaches post-create. Refund = principal (from on-chain `pricePerToken`) + producer-set `bonusPerCt`. |
| CampaignRegistry | [`0xAef1Cb97C9a8CC2d06d6C662F6655009DED1E1BE`](https://sepolia.etherscan.io/address/0xAef1Cb97C9a8CC2d06d6C662F6655009DED1E1BE) | `(campaign → metadataURI)` + monotonic version. |
| ProducerRegistry | [`0x8DDc90F40Bf8847672EA5B256d93607F42Fd540E`](https://sepolia.etherscan.io/address/0x8DDc90F40Bf8847672EA5B256d93607F42Fd540E) | KYC role + producer-self-served profile. |

### Stablecoins (testnet mocks, public mint)

| Contract | Address | Decimals | Treasury accepted |
|---|---|---:|:-:|
| MockUSDC | [`0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E`](https://sepolia.etherscan.io/address/0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E) | 6 | ✅ |
| MockUSDT | [`0x7c47aa550061117f8440128c6b829da5bf88de06`](https://sepolia.etherscan.io/address/0x7c47aa550061117f8440128c6b829da5bf88de06) | 6 | ✅ |
| MockDAI | [`0x3540ea8a6fa084a31321e790b89a6fbe677ae00e`](https://sepolia.etherscan.io/address/0x3540ea8a6fa084a31321e790b89a6fbe677ae00e) | 18 | ✅ |

Each peg feed is a `MockOracle($1, 8-dec)` deployed alongside the
stablecoin and wired with 24h heartbeat + 95-105% depeg band.

### GROW system (deployed 2026-05-12 on top of v4 core, block 10838846)

| Contract | Address | Notes |
|---|---|---|
| **GrowfiToken** (proxy) | [`0x9bB4f9C41ed922282C181f2f3e01d8384c960b44`](https://sepolia.etherscan.io/address/0x9bB4f9C41ed922282C181f2f3e01d8384c960b44) | Genesis: 0 to deployer, 100k to Treasury reserve (excluded from `circulating`). Boot reference price $0.10, 10% markup. |
| **GrowfiTreasury** (proxy) | [`0xB71D13F80ceAed17A179B4e0D9eb1e8410DeaDDd`](https://sepolia.etherscan.io/address/0xB71D13F80ceAed17A179B4e0D9eb1e8410DeaDDd) | `automationEnabled=true`. Tracks Olive + Etna. Treasury excluded from Minter emission (no recursion). |
| **GrowfiMinter** (proxy) | [`0xD99c1985B257a4A55bA8D0836Fab536389cdd24C`](https://sepolia.etherscan.io/address/0xD99c1985B257a4A55bA8D0836Fab536389cdd24C) | 3-tier bonding curve 1.0×/0.7×/0.4× over cumulative USD per campaign. |
| **GrowfiFeeSplitter** (proxy) | [`0xF1a8527E00916588f4Bb137cE450E8459b6BD436`](https://sepolia.etherscan.io/address/0xF1a8527E00916588f4Bb137cE450E8459b6BD436) | 30% Treasury / 70% Ops. Set as `factory.protocolFeeRecipient`. |
| **GrowfiStakingPool** (proxy) | [`0xD1D8491370A8CF597bEcFc49D3253BfFAF34CDc8`](https://sepolia.etherscan.io/address/0xD1D8491370A8CF597bEcFc49D3253BfFAF34CDc8) | Stake $GROW, earn USDC via `Treasury.claimUsdcAndDistribute`. |

### Seed campaigns (smoke 2026-05-12)

| Campaign | Address | Token | Price |
|---|---|---|---:|
| Olive Sicily | [`0x3280d078424FDE86fdE23688561FF377278071de`](https://sepolia.etherscan.io/address/0x3280d078424FDE86fdE23688561FF377278071de) | `OLIVE` | $0.144 |
| Vineyard of Etna | [`0xd99EB722e7D4499f95A60FEEB19Cd1057bad8F2c`](https://sepolia.etherscan.io/address/0xd99EB722e7D4499f95A60FEEB19Cd1057bad8F2c) | `ETNA` | $0.10 |

### Frontend env (Sepolia ETH)

```ini
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_FACTORY_ADDRESS=0xa4DEd8Ab35e89bCAF1f7DFeb7aB2c1ED533b3f05
NEXT_PUBLIC_USDC_ADDRESS=0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E
NEXT_PUBLIC_USDT_ADDRESS=0x7c47aa550061117f8440128c6b829da5bf88de06
NEXT_PUBLIC_DAI_ADDRESS=0x3540ea8a6fa084a31321e790b89a6fbe677ae00e
NEXT_PUBLIC_REGISTRY_ADDRESS=0xAef1Cb97C9a8CC2d06d6C662F6655009DED1E1BE
NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=0x8DDc90F40Bf8847672EA5B256d93607F42Fd540E
NEXT_PUBLIC_GROW_TOKEN=0x9bB4f9C41ed922282C181f2f3e01d8384c960b44
NEXT_PUBLIC_GROW_TREASURY=0xB71D13F80ceAed17A179B4e0D9eb1e8410DeaDDd
NEXT_PUBLIC_GROW_MINTER=0xD99c1985B257a4A55bA8D0836Fab536389cdd24C
NEXT_PUBLIC_GROW_FEE_SPLITTER=0xF1a8527E00916588f4Bb137cE450E8459b6BD436
NEXT_PUBLIC_GROW_STAKING_POOL=0xD1D8491370A8CF597bEcFc49D3253BfFAF34CDc8
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/4.0.1/gn
```

---

## Base Sepolia (chain 84532) — legacy v3.3 (archived)

**Deployed:** 2026-04-28 (v3.3 fresh demo redeploy) · **Deployer/owner:** `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33`

> Fresh full redeploy of every contract for a clean demo platform —
> factory + 5 impls + mUSDC mock + 2 registries from a single forge
> session. The deployer/owner has been granted `KYC_ADMIN_ROLE` on the
> ProducerRegistry and KYC-flagged the seed producer (Alice = deployer).
>
> Single seeded test campaign on the new factory at
> `0xEECa254825e78e995D630701D26c7356887Ec6c9`: $50,400 max raise,
> $5,000/yr commitment from year 2030, 3 harvests covered by $15,000
> USDC of collateral; Alice + Bob both staked, season 1 running.
>
> Subgraph: tag `prod` now points at `growfi/2.9.0`, indexed from the
> new factory deploy block.
>
> Earlier deploys abandoned: `0xD5C6…79D` (v3.3 first), `0x91fD…6BDD`
> (v3.0), `0xDE26…bF9f` (v3.1), `0x5178…FF64` (pre-v3).
>
> All v3 mechanics carry forward unchanged: `expectedAnnualHarvestUsd`,
> `expectedAnnualHarvest`, `firstHarvestYear`, `coverageHarvests`
> immutable per-campaign; `Campaign.lockCollateral` (cumulative, no
> withdraw); permissionless `Campaign.settleSeasonShortfall(seasonId)`
> after `usdcDeadline` lapses, wired to
> `HarvestManager.depositFromCollateral` for the holder-side top-up;
> ProducerRegistry KYC role gated to `KYC_ADMIN_ROLE` admins set by the
> registry's 2-step owner.
>
> Funding fee 3% (`Campaign.buy` skim) and harvest fee 2%
> (`HarvestManager.depositUSDC`) unchanged.

### Entry points (user-facing)

| Contract | Address | Purpose |
|---|---|---|
| **CampaignFactory** (proxy) | [`0x26dfae1d399a737708aab1f9a116eb814e98ee87`](https://sepolia.basescan.org/address/0x26dfae1d399a737708aab1f9a116eb814e98ee87) | v3.3 — permissionless campaign creation. Deploy block `40817442`. |
| **CampaignRegistry** | [`0x40696756DE89c0C5DF59219e565b4a1F18e909ea`](https://sepolia.basescan.org/address/0x40696756DE89c0C5DF59219e565b4a1F18e909ea) | Onchain map `campaign → metadataURI` + monotonic `version`. Deploy block `40817471`. |
| **ProducerRegistry** | [`0xe5ed3b78631a02EAB46477F67c2b41Ec31a97A21`](https://sepolia.basescan.org/address/0xe5ed3b78631a02EAB46477F67c2b41Ec31a97A21) | v3 — owner-controlled KYC role + producer-self-served profile. Deploy block `40817476`. |
| **MockUSDC** | [`0x9c92c69a92173548a8e62a412e963f4b93ee2a13`](https://sepolia.basescan.org/address/0x9c92c69a92173548a8e62a412e963f4b93ee2a13) | 6-dec testnet USDC. Public `mint(to, amount)`. Pre-v3.3-redeploy mUSDCs abandoned. |

### Test campaign (single)

| Field | Value |
|---|---|
| Campaign proxy | [`0xEECa254825e78e995D630701D26c7356887Ec6c9`](https://sepolia.basescan.org/address/0xEECa254825e78e995D630701D26c7356887Ec6c9) |
| Producer (KYC ✓) | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` (alice) |
| pricePerToken | $0.144 |
| minCap | 100,000 OLIVE ($14,400) |
| maxCap | 350,000 OLIVE ($50,400) |
| expectedAnnualHarvestUsd | $5,000/yr (≈ 9.92% implied yield at full raise) |
| expectedAnnualHarvest | 250 L/yr (premium olive oil → implied ≈ $20/L) |
| firstHarvestYear | 2030 |
| coverageHarvests | 3 (covers 2030–2032) |
| collateralLocked | $15,000 USDC |
| Initial state | Active, season 1 running (Alice+Bob staked) |

### Implementations (used for each new campaign's proxies)

| Contract | Address |
|---|---|
| Campaign impl (v3.3) | [`0x7350cc5b192f9f03eaa40fafb206f15b9be5e282`](https://sepolia.basescan.org/address/0x7350cc5b192f9f03eaa40fafb206f15b9be5e282) |
| CampaignToken impl | [`0xb21a38294fbf740d7c66054c1a288a3c68ff6f96`](https://sepolia.basescan.org/address/0xb21a38294fbf740d7c66054c1a288a3c68ff6f96) |
| StakingVault impl | [`0x5ec4bd275d878b33a31be0d5798949033727f38d`](https://sepolia.basescan.org/address/0x5ec4bd275d878b33a31be0d5798949033727f38d) |
| YieldToken impl | [`0xf7d9376b75ed66f16f5891b195451a80bc4cf715`](https://sepolia.basescan.org/address/0xf7d9376b75ed66f16f5891b195451a80bc4cf715) |
| HarvestManager impl (v3 — depositFromCollateral) | [`0x4f9efaf3df08cc7090aff6a64cee1ec2c316d790`](https://sepolia.basescan.org/address/0x4f9efaf3df08cc7090aff6a64cee1ec2c316d790) |
| Factory impl (v3.3) | [`0xef5cbe2a426cb51f4f7fbe3f4be5cbc1a0515411`](https://sepolia.basescan.org/address/0xef5cbe2a426cb51f4f7fbe3f4be5cbc1a0515411) |

Prior Campaign/Factory impls (archived, on the abandoned 0x5178…FF64 factory):
- Campaign v2 (3% funding fee): `0xfb80BC2bCEd8cc7a97C5DD52e718981ef647ECa2`
- Campaign v1 (sell-back @ maxCap + setters): `0xD523683685D1e4d93A0Aa7d077a47F56848bc0D8`
- Factory v2: `0x3Fc470071F1e5DE4571BcaB46501416A8a2B89eD`
- Factory v1: `0xad06176c9BC2fc9B78e4500937B4779Efe03f06c`

### Configuration

| Parameter | Value |
|---|---|
| Factory owner | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Protocol fee recipient | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Funding-side fee (bps) | 300 (= 3% skimmed off every `buy()` gross inflow, non-refundable on buyback) |
| Yield-side fee (bps) | 200 (= 2% skimmed off every `HarvestManager.depositUSDC`) |
| Sequencer uptime feed | `0x0000…0000` (testnet, no sequencer guard) |
| USDC | MockUSDC (see above) |
| `minSeasonDuration` | 1 hour (relaxed from 30 days for testnet smokes) |

> Lower the floor for fast testnet smokes: `cast send <FACTORY> "setMinSeasonDuration(uint256)" 3600 --rpc-url ... --private-key $OWNER_PK`.

### 2-step USDC redeem

HarvestManager implements the commit/deposit/claim split:

| Step | Function | Event |
|---|---|---|
| 1. commit | `redeemUSDC(seasonId, yieldAmount)` — burns $YIELD, registers pending claim | `USDCCommitted(user, seasonId, yieldBurned, usdcAmount)` |
| 2. fund | `depositUSDC(seasonId, amount)` — producer tops up the pool (98/2 split) | `USDCDeposited` |
| 3. claim | `claimUSDC(seasonId)` — holder pulls pro-rata USDC | `USDCRedeemed(user, seasonId, amount)` |

Full UX spec in `docs/REDEEM_2STEP.md`.

---

## Subgraph

- Version `2.9.0` (tagged `prod`)
- Deployed: 2026-04-28
- API: `https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn`
- Pin version: replace `prod` with `2.9.0` (useful during schema migrations so an older frontend can stick to a previous version).

---

## Frontend `.env.local`

```bash
NEXT_PUBLIC_CHAIN_ID=84532
NEXT_PUBLIC_FACTORY_ADDRESS=0x26dfae1d399a737708aab1f9a116eb814e98ee87
NEXT_PUBLIC_USDC_ADDRESS=0x9c92c69a92173548a8e62a412e963f4b93ee2a13
NEXT_PUBLIC_REGISTRY_ADDRESS=0x40696756DE89c0C5DF59219e565b4a1F18e909ea
NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=0xe5ed3b78631a02EAB46477F67c2b41Ec31a97A21
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn
NEXT_PUBLIC_BACKEND_URL=http://localhost:4001
```

> **EIP-55 gotcha**: viem's address validator rejects mixed-case strings that aren't valid EIP-55 checksums. Run `cast to-check-sum-address 0x...` after any new deploy. The addresses above are already in the correct checksum form.

---

## Quick interactions

### Get test USDC (anyone)

```bash
cast send 0x9c92c69a92173548a8e62a412e963f4b93ee2a13 \
  "mint(address,uint256)" <YOUR_ADDRESS> 10000000000 \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# → 10,000 mUSDC (6 decimals)
```

### Read factory state

```bash
cast call 0x26dfae1d399a737708aab1f9a116eb814e98ee87 \
  "getCampaignCount()(uint256)" --rpc-url https://sepolia.base.org
```

### Create a campaign (as producer)

Use the frontend at `/create`, or raw call:

```bash
cast send 0x26dfae1d399a737708aab1f9a116eb814e98ee87 \
  "createCampaign((address,string,string,string,string,uint256,uint256,uint256,uint256,uint256,uint256))" \
  "(<YOUR_ADDRESS>,Olive Tree,OLIVE,Olive Yield,oYIELD,144000000000000000,10000000000000000000000,100000000000000000000000,$(( $(date +%s) + 7776000 )),15552000,5000000000000000000)" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# price 0.144 USD, minCap 10k, maxCap 100k, deadline +90d, season 180d, minProductClaim 5e18
```

### Set/update producer profile (any address)

```bash
cast send 0xe5ed3b78631a02EAB46477F67c2b41Ec31a97A21 \
  "setProfile(string)" \
  "https://growfi-media.fra1.digitaloceanspaces.com/profiles/<cid>.json" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

### Set/update campaign metadata URI (as producer)

```bash
cast send 0x40696756DE89c0C5DF59219e565b4a1F18e909ea \
  "setMetadata(address,string)" \
  <CAMPAIGN_PROXY_ADDRESS> "https://growfi-media.fra1.digitaloceanspaces.com/metadata/<cid>.json" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

---

## Backend endpoints (port 4001)

| Endpoint | Purpose |
|---|---|
| `POST /api/upload` | multipart image → DO Spaces |
| `POST /api/metadata` | campaign metadata JSON → DO Spaces |
| `POST /api/producer` | producer profile JSON → DO Spaces |
| `GET /api/snapshot/:campaign/:seasonId` | per-holder $YIELD snapshot for the reportHarvest flow |
| `POST /api/merkle/generate` | builds + stores the Merkle tree; returns `{ root, url, count }` |
| `GET /api/merkle/:campaign/:seasonId/:user` | returns `{ user, productAmount, proof }` for product redemption |

---

## Reset / redeploy

```bash
source .env
forge script script/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org \
  --broadcast --slow --private-key $PRIVATE_KEY
FACTORY=<new factory proxy> forge script script/DeployRegistry.s.sol \
  --rpc-url https://sepolia.base.org --broadcast --private-key $PRIVATE_KEY
forge script script/DeployProducerRegistry.s.sol \
  --rpc-url https://sepolia.base.org --broadcast --private-key $PRIVATE_KEY
```

After deploying, bump `platform/subgraph/package.json` version, update `platform/subgraph/subgraph.yaml` addresses + startBlocks, then:

```bash
cd platform/subgraph
for n in Campaign CampaignFactory CampaignToken CampaignRegistry HarvestManager ProducerRegistry StakingVault YieldToken; do
  jq '.abi' ../../out/$n.sol/$n.json > abis/$n.json
done
npm run prepare
npm run deploy:goldsky:prod
```

Update `platform/frontend/.env.local` + `src/contracts/tokens.ts` (KNOWN_TOKENS mUSDC address) + re-extract ABIs to `src/contracts/abis/`.
