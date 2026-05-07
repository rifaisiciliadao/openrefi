# GrowFi Subgraph — Deploy su Goldsky

**Team:** turinglabs · **Progetto:** growfi · **Network:** base-sepolia

## Deployments indicizzati

| Parametro | Valore |
|-----------|--------|
| Chain | Base Sepolia (id 84532) |
| Factory | [`0x3fA41528a22645Bef478E9eBae83981C02e98f74`](https://sepolia.basescan.org/address/0x3fA41528a22645Bef478E9eBae83981C02e98f74) |
| Start block | `40322865` |

Già configurato in `subgraph.yaml`. Vedi `CONTRACTS.md` alla root del repo per tutto il resto.

---

## 1. Install + login

```bash
cd platform/subgraph
npm install
npm run goldsky:login     # incolla la tua API key
```

API key reperibile da https://app.goldsky.com → Settings → API Keys.

---

## 2. Build + deploy

```bash
npm run prepare            # codegen + build in build/
npm run deploy:goldsky:prod
```

Questo pubblica `growfi/1.0.0` e lo tagga come `prod`.

Dopo il deploy Goldsky stampa un `PROJECT_ID`. Salvalo nel `.env.local` del frontend:

```
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/<PROJECT_ID>/subgraphs/growfi/prod/gn
```

---

## 3. Aggiornamento di una nuova versione

1. Incrementa `version` in `package.json` (semver)
2. `npm run prepare && npm run deploy:goldsky`
3. (opz.) `npm run deploy:goldsky:promote` per spostare il tag `prod` a questa versione

Goldsky mantiene più versioni in parallelo — utile per rollback.

---

## 4. Log e debug

```bash
npm run goldsky:logs       # live log indexer
npm run goldsky:list       # lista subgraph del team
```

---

## Problemi noti

| Sintomo | Cosa controllare |
|---------|------------------|
| `401 Unauthorized` | Re-esegui `goldsky login` |
| `Subgraph name already taken` | Incrementa `version` in `package.json` |
| Indexer fermo al block di start | Verifica che la factory emetta eventi (crea una campagna o chiama USDC.mint per debug) |
| Handler vanno in overflow / crash | `npm run goldsky:logs` per stack trace, poi `npm run codegen` dopo modifiche agli ABI |
| Schema change breaking | Bump **minor** in semver, i dati vecchi restano sulla versione precedente |

---

## Teardown

```bash
npm run goldsky:delete    # ATTENZIONE: elimina gli indici della versione corrente
```

## v4 — GROW system + rename

The v4 redeploy adds:

1. **Renamed contracts** (Growfi prefix on all 8). ABIs are re-extracted; existing handler files (campaign.ts, factory.ts, ...) still reference the old aliases (CampaignFactory etc.) but the underlying ABI JSON content is up to date so codegen produces the right types.

2. **GROW system** (4 new contracts):
   - GrowfiToken (`./src/grow/token.ts`) — Transfer, DirectBuy, GenesisMinted, sale config events
   - GrowfiTreasury (`./src/grow/treasury.ts`) — StablecoinAccepted/Revoked, CampaignTracked/Untracked, Allocated, Redeemed, TokenRescued
   - GrowfiMinter (`./src/grow/minter.ts`) — CampaignRegistered, GrowEscrowed, GrowMinted, SoftCapReached, CampaignBuyback, EscrowClaimed, BondingCurveUpdated
   - GrowfiFeeSplitter (`./src/grow/splitter.ts`) — Flushed

3. **New entities** in `schema.graphql`: GrowToken, GrowHolder, GrowDirectBuy, GrowEscrow, GrowEscrowClaim, CampaignGrowState, BondingCurveSnapshot, GrowfiTreasuryState, StablecoinAcceptance, TreasuryAllocation, TreasuryRedemption, TreasuryRescue, FeeFlush.

### Post-deploy steps for v4

After running the v4 deploy script:

1. Replace the four `0x0000...0000` placeholder addresses in `subgraph.yaml` (the `GrowfiToken`, `GrowfiTreasury`, `GrowfiMinter`, `GrowfiFeeSplitter` data sources) with the actual proxy addresses.
2. Replace each `startBlock: 0` in those four sources with the deploy block.
3. Update the existing data sources (CampaignFactory, CampaignRegistry, ProducerRegistry, plus the dynamic templates) with their new v4 addresses + start blocks. The ABIs are already re-extracted as `Growfi*.json`.
4. Optionally rename the abi `name` aliases in `subgraph.yaml` from `Campaign` → `GrowfiCampaign` etc. for clarity, and update handler imports accordingly. (Not strictly required — the subgraph runs on event signatures, not contract names.)
5. Run:
   ```bash
   npm run prepare
   npm run deploy:goldsky:prod
   ```
6. Verify on Goldsky that all data sources index from the new start blocks.
