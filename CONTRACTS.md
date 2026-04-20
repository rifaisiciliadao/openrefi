# GrowFi — Deployments

## Base Sepolia (chain 84532)

**Deployed:** 2026-04-20 (fresh redeploy) · **Deployer/owner:** `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33`

> Previous addresses (pre-2026-04-20) are dead. This redeploy ships the
> Campaign.sol fix that lets sell-back queue orders be consumed at maxCap
> (pre-fix the `currentSupply >= maxCap` guard made the queue unreachable
> once the campaign was fully funded, defeating the feature). See
> `test/SellBackAtMaxCap.t.sol` for the regression suite.

### Entry points (user-facing)

| Contract | Address | Purpose |
|---|---|---|
| **CampaignFactory** (proxy) | [`0x199B430359595AD09d42F697f33f44dDFd658C12`](https://sepolia.basescan.org/address/0x199B430359595AD09d42F697f33f44dDFd658C12) | Permissionless campaign creation. `createCampaign(params)` with `msg.sender == params.producer`. Deploy block `40452808`. |
| **CampaignRegistry** | [`0xe996a49a576bb4047C66821e48C9ea3Ce762f628`](https://sepolia.basescan.org/address/0xe996a49a576bb4047C66821e48C9ea3Ce762f628) | Onchain map `campaign → metadataURI` + monotonic `version`. Producer-only write, gated by `factory.isCampaign`. Indexed by the subgraph into `Campaign.metadataURI` / `.metadataVersion`. Deploy block `40452852`. |
| **ProducerRegistry** | [`0xB804de4d151E5A8a9EBa61a9904EC3588c8EFb56`](https://sepolia.basescan.org/address/0xB804de4d151E5A8a9EBa61a9904EC3588c8EFb56) | Onchain map `producer address → profileURI` + monotonic `version`. Zero-admin; `setProfile(uri)` writes only the caller's own row. Indexed into the subgraph `Producer` entity. Deploy block `40452862`. EIP-55 checksum must match exactly — viem rejects other casings. |
| **MockUSDC** | [`0xe307a7F03d62b446558b3D6c232a42830d9a2037`](https://sepolia.basescan.org/address/0xe307a7F03d62b446558b3D6c232a42830d9a2037) | 6-dec testnet USDC. Public `mint(to, amount)` — anyone can mint any amount. |

### Implementations (used for each new campaign's proxies)

| Contract | Address |
|---|---|
| Campaign impl (sell-back @ maxCap fix) | [`0x1aE04bd38332F0B73F378aBD13b560c1Fd028557`](https://sepolia.basescan.org/address/0x1aE04bd38332F0B73F378aBD13b560c1Fd028557) |
| CampaignToken impl | [`0x341be87780D6Ce9F7785900D3245CB61Fb3b1AE1`](https://sepolia.basescan.org/address/0x341be87780D6Ce9F7785900D3245CB61Fb3b1AE1) |
| StakingVault impl | [`0x44c6fFB39505287c5e4cB4c1E1d6119504bcEaab`](https://sepolia.basescan.org/address/0x44c6fFB39505287c5e4cB4c1E1d6119504bcEaab) |
| YieldToken impl | [`0x7b03B539958DB590813ba9ca8788F5DdCA4e1b75`](https://sepolia.basescan.org/address/0x7b03B539958DB590813ba9ca8788F5DdCA4e1b75) |
| HarvestManager impl (2-step redeem) | [`0x2A53fFd704eF93B001aB7439f08E13d6836fC336`](https://sepolia.basescan.org/address/0x2A53fFd704eF93B001aB7439f08E13d6836fC336) |
| Factory impl | [`0x71bFC33642477f86cd9A2aD50Dd63dEd170F4Ec5`](https://sepolia.basescan.org/address/0x71bFC33642477f86cd9A2aD50Dd63dEd170F4Ec5) |

### Configuration

| Parameter | Value |
|---|---|
| Factory owner | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Protocol fee recipient | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Protocol fee (bps) | 200 (= 2%) |
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

- Version `2.0.0` (tagged `prod`)
- Deployed: 2026-04-20
- API: `https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn`
- Pin version: replace `prod` with `2.0.0` (useful during schema migrations so an older frontend can stick to a previous version).

---

## Frontend `.env.local`

```bash
NEXT_PUBLIC_CHAIN_ID=84532
NEXT_PUBLIC_FACTORY_ADDRESS=0x199B430359595AD09d42F697f33f44dDFd658C12
NEXT_PUBLIC_USDC_ADDRESS=0xe307a7F03d62b446558b3D6c232a42830d9a2037
NEXT_PUBLIC_REGISTRY_ADDRESS=0xe996a49a576bb4047C66821e48C9ea3Ce762f628
NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=0xB804de4d151E5A8a9EBa61a9904EC3588c8EFb56
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn
NEXT_PUBLIC_BACKEND_URL=http://localhost:4001
```

> **EIP-55 gotcha**: viem's address validator rejects mixed-case strings that aren't valid EIP-55 checksums. Run `cast to-check-sum-address 0x...` after any new deploy. The addresses above are already in the correct checksum form.

---

## Quick interactions

### Get test USDC (anyone)

```bash
cast send 0xe307a7F03d62b446558b3D6c232a42830d9a2037 \
  "mint(address,uint256)" <YOUR_ADDRESS> 10000000000 \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# → 10,000 mUSDC (6 decimals)
```

### Read factory state

```bash
cast call 0x199B430359595AD09d42F697f33f44dDFd658C12 \
  "getCampaignCount()(uint256)" --rpc-url https://sepolia.base.org
```

### Create a campaign (as producer)

Use the frontend at `/create`, or raw call:

```bash
cast send 0x199B430359595AD09d42F697f33f44dDFd658C12 \
  "createCampaign((address,string,string,string,string,uint256,uint256,uint256,uint256,uint256,uint256))" \
  "(<YOUR_ADDRESS>,Olive Tree,OLIVE,Olive Yield,oYIELD,144000000000000000,10000000000000000000000,100000000000000000000000,$(( $(date +%s) + 7776000 )),15552000,5000000000000000000)" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# price 0.144 USD, minCap 10k, maxCap 100k, deadline +90d, season 180d, minProductClaim 5e18
```

### Set/update producer profile (any address)

```bash
cast send 0xB804de4d151E5A8a9EBa61a9904EC3588c8EFb56 \
  "setProfile(string)" \
  "https://growfi-media.fra1.digitaloceanspaces.com/profiles/<cid>.json" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

### Set/update campaign metadata URI (as producer)

```bash
cast send 0xe996a49a576bb4047C66821e48C9ea3Ce762f628 \
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
