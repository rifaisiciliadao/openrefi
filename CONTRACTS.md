# GrowFi — Deployments

## Base Sepolia (chain 84532)

**Deployed:** 2026-04-17 · **Deployer/owner:** `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33`

### Entry points (user-facing)

| Contract | Address | Purpose |
|---|---|---|
| **CampaignFactory** (proxy) | [`0x3fA41528a22645Bef478E9eBae83981C02e98f74`](https://sepolia.basescan.org/address/0x3fA41528a22645Bef478E9eBae83981C02e98f74) | Permissionless campaign creation. `createCampaign(params)` with `msg.sender == params.producer`. |
| **CampaignRegistry** | [`0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e`](https://sepolia.basescan.org/address/0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e) | Onchain map `campaign → metadataURI` + monotonic `version`. Producer-only write, gated by `factory.isCampaign`. Indexed by the subgraph into `Campaign.metadataURI` / `.metadataVersion`. Deploy block `40331554`. |
| **MockUSDC** | [`0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E`](https://sepolia.basescan.org/address/0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E) | 6-dec testnet USDC. Public `mint(to, amount)` — anyone can mint any amount. |

### Implementations (used for each new campaign's proxies)

| Contract | Address | Deploy tx |
|---|---|---|
| Campaign impl | [`0x61afa5fDfB09b465Dafc5b868E186Dec832DE945`](https://sepolia.basescan.org/address/0x61afa5fDfB09b465Dafc5b868E186Dec832DE945) | [`0xa2ce96a2…`](https://sepolia.basescan.org/tx/0xa2ce96a2e85597d654b8823856776b0af9863cac60038d0de8b1e6a2cd8ded33) |
| CampaignToken impl | [`0x0DBE11aD9c2bf4126FE8D422e7374dE47600A2ca`](https://sepolia.basescan.org/address/0x0DBE11aD9c2bf4126FE8D422e7374dE47600A2ca) | [`0x7228dd72…`](https://sepolia.basescan.org/tx/0x7228dd7263f8f4515c26f1eeb08893296823e01a94f4ba568530a8b7bf7ee3ff) |
| StakingVault impl | [`0x81C4e22EC9198f2983217C483e4027cf49E940db`](https://sepolia.basescan.org/address/0x81C4e22EC9198f2983217C483e4027cf49E940db) | [`0xfd70b3fb…`](https://sepolia.basescan.org/tx/0xfd70b3fb2ff4d67d4bcd0a4535c89fa976039a76800d06894bd3679789e1edd9) |
| YieldToken impl | [`0x092Ed1e0845f6817e24316A730E98ec074e5F017`](https://sepolia.basescan.org/address/0x092Ed1e0845f6817e24316A730E98ec074e5F017) | [`0x562a768b…`](https://sepolia.basescan.org/tx/0x562a768b969623760de624f76cf9b7ef6f3f9b90504044f9a032f42880c2f051) |
| HarvestManager impl | [`0x8d434e38dd91D9b738f8803dbD18b815720BEDad`](https://sepolia.basescan.org/address/0x8d434e38dd91D9b738f8803dbD18b815720BEDad) | [`0x3903da59…`](https://sepolia.basescan.org/tx/0x3903da595b989062e36f4ae530a7f70e1c2be712a1723f9b265832d55c8f3373) |
| Factory impl | [`0x38da3922d3Bc3281F57946618404F0E341777F68`](https://sepolia.basescan.org/address/0x38da3922d3Bc3281F57946618404F0E341777F68) | [`0xfee08622…`](https://sepolia.basescan.org/tx/0xfee08622258e8cefd67940446e2a4a777bf4b463f7b4f3dd4da19592f98045f1) |

### Configuration

| Parameter | Value |
|---|---|
| Factory owner | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Protocol fee recipient | `0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33` |
| Protocol fee (bps) | 200 (= 2%) |
| Sequencer uptime feed | `0x0000…0000` (testnet, no sequencer guard) |
| USDC | MockUSDC (see above) |
| `minSeasonDuration` (V2) | `3600` sec (= 1 hour) — relaxed for testnet. Mainnet default is 30 days. |

### Factory V2 upgrade (2026-04-17)

| Item | Value |
|---|---|
| New factory impl | [`0x4Cd93a22f91Ab965a7c9e55045a41afb52b926b6`](https://sepolia.basescan.org/address/0x4Cd93a22f91Ab965a7c9e55045a41afb52b926b6#code) |
| Factory ProxyAdmin | [`0xe501150BB81937Ff18B4a18c1eDB4Be1c787e01A`](https://sepolia.basescan.org/address/0xe501150BB81937Ff18B4a18c1eDB4Be1c787e01A) |
| Upgrade script | `script/UpgradeFactoryV2.s.sol` |

V2 adds `minSeasonDuration` as a `uint256` storage field + `setMinSeasonDuration(uint256)` onlyOwner setter + `initializeV2()` reinitializer. Existing `createCampaign` validation switched from hardcoded `>= 30 days` to `>= minSeasonDuration`.

### Smoke test campaigns (for integration testing)

| Campaign | Address | Season duration | State | Notes |
|---|---|---|---|---|
| SMOKE (default) | [`0x1bB2084dE7F56A31CF5B11Ad5788bf236Ada5266`](https://sepolia.basescan.org/address/0x1bB2084dE7F56A31CF5B11Ad5788bf236Ada5266) | 180 days | Funding (1 SMOKE bought, below minCap 10k) | created via `script/SmokeTest.s.sol` |
| FAST (1-hour) | [`0x17c152432D066ccE7599fB3612c4CFBf58555977`](https://sepolia.basescan.org/address/0x17c152432D066ccE7599fB3612c4CFBf58555977) | 1 hour | Active, season 1 running | created via `script/SmokeTest1h.s.sol` |

FAST campaign peripherals:
- CampaignToken: `0xe6C3182D62D331B0DEA867c96fbDFe5f28C36710`
- StakingVault: `0x35477E7a3400851f74a60bd8Dc14201C742B2a7A`
- YieldToken: `0x42ddf5c40cA5dA832b29aC64316AaaeD1e99f2fD`
- HarvestManager: `0x4796C635cEe0128259db6517853A97415DD8D35C`
- Producer staked 104.16 FAST tokens (positionId 0) at season start. Wait ≥1 hour then `endSeason + reportHarvest + claimYield`.

---

## Frontend `.env.local`

```bash
NEXT_PUBLIC_CHAIN_ID=84532
NEXT_PUBLIC_FACTORY_ADDRESS=0x3fA41528a22645Bef478E9eBae83981C02e98f74
NEXT_PUBLIC_USDC_ADDRESS=0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E
NEXT_PUBLIC_REGISTRY_ADDRESS=0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn
```

---

## Quick interactions

### Get test USDC (anyone)

```bash
cast send 0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E \
  "mint(address,uint256)" <YOUR_ADDRESS> 10000000000 \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# → 10,000 mUSDC (6 decimals)
```

### Read factory state

```bash
cast call 0x3fA41528a22645Bef478E9eBae83981C02e98f74 \
  "getCampaignCount()(uint256)" --rpc-url https://sepolia.base.org
```

### Create a campaign (as producer)

Use the frontend at `/create`, or raw call:

```bash
cast send 0x3fA41528a22645Bef478E9eBae83981C02e98f74 \
  "createCampaign((address,string,string,string,string,uint256,uint256,uint256,uint256,uint256,uint256))" \
  "(<YOUR_ADDRESS>,Olive Tree,OLIVE,Olive Yield,oYIELD,144000000000000000,10000000000000000000000,100000000000000000000000,$(( $(date +%s) + 7776000 )),15552000,5000000000000000000)" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
# price 0.144 USD, minCap 10k, maxCap 100k, deadline +90d, season 180d, minProductClaim 5e18
```

### Set/update campaign metadata URI (as producer)

```bash
cast send 0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e \
  "setMetadata(address,string)" \
  <CAMPAIGN_PROXY_ADDRESS> "https://growfi-media.fra1.digitaloceanspaces.com/metadata/<cid>.json" \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

Emits `MetadataSet(campaign, producer, version, uri)`. Subgraph picks it up and writes `Campaign.metadataURI` + `Campaign.metadataVersion` within a few seconds. Producers can call again to rotate the URL — `version` increments, `metadataURI` is overwritten.

### Upgrade a campaign contract (as producer)

Each of your campaign's 5 proxies has an auto-deployed `ProxyAdmin` owned by you (the producer). To upgrade:

```bash
# 1. Find the ProxyAdmin of the proxy you want to upgrade
cast storage <CAMPAIGN_PROXY_ADDRESS> \
  0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 \
  --rpc-url https://sepolia.base.org
# That's the ERC-1967 admin slot. The returned 32-byte value is the ProxyAdmin address (last 20 bytes).

# 2. Deploy a new implementation (e.g. CampaignV2).

# 3. Call upgradeAndCall via ProxyAdmin
cast send <PROXY_ADMIN_ADDRESS> \
  "upgradeAndCall(address,address,bytes)" \
  <CAMPAIGN_PROXY_ADDRESS> <NEW_IMPL_ADDRESS> 0x \
  --rpc-url https://sepolia.base.org --private-key $YOUR_PK
```

### Swap default impl for future campaigns (as factory owner)

```bash
# Example: swap Campaign implementation that new campaigns get by default
cast send 0x3fA41528a22645Bef478E9eBae83981C02e98f74 \
  "setCampaignImpl(address)" <NEW_IMPL> \
  --rpc-url https://sepolia.base.org --private-key $OWNER_PK
```

---

## Verify contracts on BaseScan

```bash
# Example for CampaignFactory impl. Repeat for each contract.
forge verify-contract \
  0x38da3922d3Bc3281F57946618404F0E341777F68 \
  src/CampaignFactory.sol:CampaignFactory \
  --chain-id 84532 \
  --verifier-url https://api-sepolia.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
  --watch
```

Constructor args: all implementations are zero-arg (use `Initializable`). For the factory proxy, see `abi.encode(address factoryImpl, address initialOwner, bytes initData)` — constructor args of `TransparentUpgradeableProxy`.

---

## Reset / redeploy

The MockUSDC and all implementations are immutable; to redeploy:

```bash
source .env
forge script script/DeployTestnet.s.sol --rpc-url https://sepolia.base.org --broadcast
```

Each invocation deploys a fresh set — old addresses become dead. Update the frontend env accordingly.
