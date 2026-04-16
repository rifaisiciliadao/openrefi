# GrowFi Subgraph — Deploy su Goldsky

**Team:** turinglabs
**Progetto:** GrowFi
**Network:** Arbitrum Sepolia

---

## 1. Pre-requisiti

```bash
# Installa le dipendenze (include @goldskycom/cli)
npm install
```

---

## 2. Imposta l'indirizzo della Factory

Prima di fare il deploy, aggiorna `subgraph.yaml` con l'indirizzo reale di `CampaignFactory` su Arbitrum Sepolia, e il block di partenza (quello del deploy del factory, NON 0 — altrimenti scansiona tutta la chain):

```yaml
dataSources:
  - kind: ethereum/contract
    name: CampaignFactory
    network: arbitrum-sepolia
    source:
      address: "0xYOUR_FACTORY_ADDRESS_HERE"   # ← sostituisci
      abi: CampaignFactory
      startBlock: 12345678                       # ← block di deploy
```

---

## 3. Goldsky login (una tantum)

```bash
npm run goldsky:login
# oppure direttamente:
npx goldsky login
```

Ti chiederà l'API key. Recuperabile da https://app.goldsky.com → Settings → API Keys.

L'account deve appartenere al team **turinglabs**.

---

## 4. Build & Deploy

```bash
# Genera i tipi TypeScript dall'ABI + schema, poi compila in WASM
npm run prepare

# Deploy su Goldsky
npm run deploy:goldsky
```

Questo pubblica il subgraph con tag `growfi/1.0.0` (versione letta da `package.json`).

---

## 5. Aggiornare il deploy

Per ogni nuova versione:

1. Incrementa `version` in `package.json` (semver: patch/minor/major)
2. Esegui di nuovo `npm run prepare && npm run deploy:goldsky`

Goldsky manterrà più tag contemporaneamente, utili per A/B testing tra versioni.

---

## 6. Tag di produzione (opzionale)

Dopo il deploy puoi promuovere una versione a "produzione" così che il frontend punti sempre all'ultima stabile senza dover cambiare URL:

```bash
npx goldsky subgraph tag create growfi/1.0.0 --tag prod
```

Il frontend usa poi l'endpoint `https://api.goldsky.com/api/public/<project-id>/subgraphs/growfi/prod/gn` invece della versione specifica.

---

## 7. Query dal frontend

L'endpoint GraphQL ha questa forma:

```
https://api.goldsky.com/api/public/<PROJECT_ID>/subgraphs/growfi/1.0.0/gn
```

`PROJECT_ID` è dato da Goldsky dopo il primo deploy. Aggiungilo a `frontend/.env.local`:

```
NEXT_PUBLIC_SUBGRAPH_URL=https://api.goldsky.com/api/public/<PROJECT_ID>/subgraphs/growfi/1.0.0/gn
```

---

## 8. Log e debug

```bash
# Live log del subgraph
npm run goldsky:logs

# Lista di tutti i subgraph del team
npm run goldsky:list
```

---

## 9. Teardown (attenzione, distrugge gli indici)

```bash
npx goldsky subgraph delete growfi/1.0.0
```

---

## Risoluzione problemi

| Problema | Soluzione |
|----------|-----------|
| `401 Unauthorized` | Rifai `goldsky login` — l'API key potrebbe essere scaduta |
| `Subgraph name already taken` | Incrementa la versione in `package.json` |
| Handler inizia a indicizzare da block 0 | Imposta `startBlock` in `subgraph.yaml` sul block di deploy del factory |
| Event signature mismatch | Rifai `npm run codegen` dopo modifiche all'ABI |
