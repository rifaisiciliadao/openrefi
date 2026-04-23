# GrowFi — Deployments

## Base Sepolia (chain 84532)

**Last upgrade:** 2026-04-23 (v2 — 3% funding fee) · **Deployer/owner:** `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33`

> Factory-proxy + default Campaign impl upgraded in place (same factory
> address, new impls). `Campaign.buy()` now skims 3% off the gross inflow
> and forwards it to `protocolFeeRecipient` — non-refundable on buyback.
> `FUNDING_FEE_BPS = 300`. The yield-side 2% at `HarvestManager.depositUSDC`
> is unchanged. Factory storage is untouched; Campaign storage keeps the
> old `protocolFeeBps` slot as a deprecated zombie for layout safety and
> appends `fundingFeeBps` at the end. Existing campaign proxies deployed
> pre-upgrade are NOT auto-migrated — their producer must call
> `ProxyAdmin.upgradeAndCall(campaignProxy, newImpl, initializeV2(300))` to
> opt in. Future campaigns created via the factory pick up the new impl
> automatically.
>
> Prior layers: 2026-04-20 added sell-back-at-maxCap fix + producer
> setters (`setFundingDeadline`, `setMinCap`, `setMaxCap`); regression
> suites live in `test/SellBackAtMaxCap.t.sol` and `test/ParamUpdates.t.sol`.

### Entry points (user-facing)

| Contract | Address | Purpose |
|---|---|---|
| **CampaignFactory** (proxy) | [`0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64`](https://sepolia.basescan.org/address/0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64) | Permissionless campaign creation. `createCampaign(params)` with `msg.sender == params.producer`. Deploy block `40456524`. |
| **CampaignRegistry** | [`0x6cfC4b78131947721A2370B594Ed81BD758a1e17`](https://sepolia.basescan.org/address/0x6cfC4b78131947721A2370B594Ed81BD758a1e17) | Onchain map `campaign → metadataURI` + monotonic `version`. Producer-only write, gated by `factory.isCampaign`. Indexed by the subgraph into `Campaign.metadataURI` / `.metadataVersion`. Deploy block `40456633`. |
| **ProducerRegistry** | [`0x2bbc8FE2626C7f83fDe22E4799E76B93Cc8b379e`](https://sepolia.basescan.org/address/0x2bbc8FE2626C7f83fDe22E4799E76B93Cc8b379e) | Onchain map `producer address → profileURI` + monotonic `version`. Zero-admin; `setProfile(uri)` writes only the caller's own row. Indexed into the subgraph `Producer` entity. Deploy block `40457114`. EIP-55 checksum must match exactly — viem rejects other casings. |
| **MockUSDC** | [`0x1b0a76431b3CfD55b3be22497F03920C71623c47`](https://sepolia.basescan.org/address/0x1b0a76431b3CfD55b3be22497F03920C71623c47) | 6-dec testnet USDC. Public `mint(to, amount)` — anyone can mint any amount. |

### Implementations (used for each new campaign's proxies)

| Contract | Address |
|---|---|
| Campaign impl (v2 — 3% funding fee) | [`0xfb80BC2bCEd8cc7a97C5DD52e718981ef647ECa2`](https://sepolia.basescan.org/address/0xfb80BC2bCEd8cc7a97C5DD52e718981ef647ECa2) |
| CampaignToken impl | [`0xBa2A6c2bc09bf1F213Bb67692E2af672B6c45524`](https://sepolia.basescan.org/address/0xBa2A6c2bc09bf1F213Bb67692E2af672B6c45524) |
| StakingVault impl | [`0x5B5CCE7aab1Eaf8fBD9d3376C4a1fcE76E94ACC1`](https://sepolia.basescan.org/address/0x5B5CCE7aab1Eaf8fBD9d3376C4a1fcE76E94ACC1) |
| YieldToken impl | [`0xbD10E5870Bb026d1b5fA7eDeEfafd913d183697d`](https://sepolia.basescan.org/address/0xbD10E5870Bb026d1b5fA7eDeEfafd913d183697d) |
| HarvestManager impl (2-step redeem) | [`0xFA92130195a1A593b06180c73e33F4448ff639B3`](https://sepolia.basescan.org/address/0xFA92130195a1A593b06180c73e33F4448ff639B3) |
| Factory impl (v2 — passes funding fee to new campaigns) | [`0x3Fc470071F1e5DE4571BcaB46501416A8a2B89eD`](https://sepolia.basescan.org/address/0x3Fc470071F1e5DE4571BcaB46501416A8a2B89eD) |

Prior Campaign/Factory impls (archived, no longer the factory default):
- Campaign v1 (sell-back @ maxCap + setters): `0xD523683685D1e4d93A0Aa7d077a47F56848bc0D8`
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
| `minSeasonDuration` | 30 days (factory default, not yet lowered) |

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

- Version `2.1.0` (tagged `prod`)
- Deployed: 2026-04-20
- API: `https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn`
- Pin version: replace `prod` with `2.1.0` (useful during schema migrations so an older frontend can stick to a previous version).

---

## Frontend `.env.local`

```bash
NEXT_PUBLIC_CHAIN_ID=84532
NEXT_PUBLIC_FACTORY_ADDRESS=0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64
NEXT_PUBLIC_USDC_ADDRESS=0x1b0a76431b3CfD55b3be22497F03920C71623c47
NEXT_PUBLIC_REGISTRY_ADDRESS=0x6cfC4b78131947721A2370B594Ed81BD758a1e17
NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=0x2bbc8FE2626C7f83fDe22E4799E76B93Cc8b379e
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn
NEXT_PUBLIC_BACKEND_URL=http://localhost:4001
```

> **EIP-55 gotcha**: viem's address validator rejects mixed-case strings that aren't valid EIP-55 checksums. Run `cast to-check-sum-address 0x...` after any new deploy. The addresses above are already in the correct checksum form.

---

## Quick interactions

### Get test USDC (anyone)

```bash
cast send 0x1b0a76431b3CfD55b3be22497F03920C71623c47 \
  "mint(address,uint256)" <YOUR_ADDRESS> 10000000000 \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# → 10,000 mUSDC (6 decimals)
```

### Read factory state

```bash
cast call 0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64 \
  "getCampaignCount()(uint256)" --rpc-url https://sepolia.base.org
```

### Create a campaign (as producer)

Use the frontend at `/create`, or raw call:

```bash
cast send 0x5178A4AB4c6400CeeB812663AFfd1bd5B0c9FF64 \
  "createCampaign((address,string,string,string,string,uint256,uint256,uint256,uint256,uint256,uint256))" \
  "(<YOUR_ADDRESS>,Olive Tree,OLIVE,Olive Yield,oYIELD,144000000000000000,10000000000000000000000,100000000000000000000000,$(( $(date +%s) + 7776000 )),15552000,5000000000000000000)" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# price 0.144 USD, minCap 10k, maxCap 100k, deadline +90d, season 180d, minProductClaim 5e18
```

### Set/update producer profile (any address)

```bash
cast send 0x2bbc8FE2626C7f83fDe22E4799E76B93Cc8b379e \
  "setProfile(string)" \
  "https://growfi-media.fra1.digitaloceanspaces.com/profiles/<cid>.json" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

### Set/update campaign metadata URI (as producer)

```bash
cast send 0x6cfC4b78131947721A2370B594Ed81BD758a1e17 \
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
