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
