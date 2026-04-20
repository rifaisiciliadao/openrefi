# GrowFi — DigitalOcean test deploy

This guide covers the **test environment** on DigitalOcean App Platform
(Frankfurt region). Production mainnet deploy will follow the same
shape but with separate secrets and a custom domain.

## What ships

- **Frontend** (`platform/frontend`): Next.js 16 in `output: "standalone"`
  mode, served on port 3000 inside the container.
- **Backend** (`platform/backend`): Fastify on port 4001, handles image
  + metadata uploads to DO Spaces, yield snapshots, merkle generation.
- **Single public HTTPS endpoint** with path-based routing:
  - `/` → frontend
  - `/api/*` → backend
- **Auto-deploy on `main`** pushes (configured in `.do/app.yaml`).

Outside the scope of this deploy (run elsewhere):
- Subgraph — lives on Goldsky (`growfi/prod` tag), see `CONTRACTS.md`.
- Contracts — already on Base Sepolia (`CONTRACTS.md`).
- Media bucket — `growfi-media` on DO Spaces, created out-of-band.

## One-time setup

### 1. Create the app (first time only)

```bash
# Authenticate. Needs a DO API token with the `apps:*` scope.
doctl auth init

# Validate the spec against DO's schema without creating anything.
doctl apps spec validate .do/app.yaml

# Create the app. Prints the new APP_ID.
doctl apps create --spec .do/app.yaml
```

Note the returned `APP_ID` — you'll need it for updates.

### 2. Inject secrets (CLI — never commit)

Two real secrets live outside the repo: `DO_SPACES_KEY` and
`DO_SPACES_SECRET`. Set them via `doctl` with a throwaway spec file
that is deleted immediately after applying:

```bash
APP_ID=<your-app-id>

# 1. Create a bucket-scoped key for this app (or reuse an existing one;
#    Spaces never shows the secret again after creation).
doctl spaces keys create growfi-app-platform \
  --grants 'bucket=growfi-media;permission=readwrite' \
  --output json

# 2. Patch the live spec via jq (no yaml toolchain needed), apply, delete
#    the tmp files. Using JSON output so `jq` can consume it directly.
doctl apps spec get $APP_ID --format json > /tmp/spec.json
jq --arg ak "<access_key>" --arg sk "<secret_key>" '
  .services |= map(
    if .name == "growfi-backend"
    then .envs += [
      {"key":"DO_SPACES_KEY","scope":"RUN_TIME","type":"SECRET","value":$ak},
      {"key":"DO_SPACES_SECRET","scope":"RUN_TIME","type":"SECRET","value":$sk}
    ]
    else .
    end
  )
' /tmp/spec.json > /tmp/spec-patched.json

doctl apps update $APP_ID --spec /tmp/spec-patched.json
rm /tmp/spec.json /tmp/spec-patched.json
```

After the update, App Platform re-deploys the backend (only — the
frontend image is unchanged since only RUN_TIME scope was touched).

`NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` is NOT a secret (it's a
rate-limit key from reown.com) and is committed in `.do/app.yaml`
at BUILD_TIME scope. Rotate from the reown dashboard if abused.

### 3. Trigger the first deploy

After saving secrets, force a rebuild from the dashboard or:

```bash
doctl apps create-deployment <APP_ID>
```

The build takes ~5-7 min (frontend dominates). First deploy URL will
be printed: `https://growfi-test-xxxxx.ondigitalocean.app`.

## Updates

### Spec changes (Dockerfile, env defaults, new service, etc.)

Edit `.do/app.yaml`, commit, push, then:

```bash
doctl apps update <APP_ID> --spec .do/app.yaml
```

Code-only changes don't need this — they auto-deploy via GitHub push
triggers (`github.deploy_on_push: true`).

### Secret rotation

Any SECRET env change is a manual dashboard edit (can't be committed).
After saving, the app re-deploys automatically.

### Build args for NEXT_PUBLIC_*

The frontend Dockerfile takes every public env var as a build ARG so
Next.js can bake it into the static bundle. If you change a contract
address (e.g. new deployment), update **both**:

1. `.do/app.yaml` → `services[growfi-frontend].envs` (the default).
2. `platform/frontend/.env.local` (so local dev matches).

Then push to `main` — App Platform rebuilds with the new ARG.

## Monitoring

- **Runtime logs**: `doctl apps logs <APP_ID> --type run` (or dashboard).
- **Build logs**: `doctl apps logs <APP_ID> --type build`.
- **Health checks**: both services expose a `HEALTHCHECK` in their
  Dockerfile — App Platform polls them every 30s and restarts on 3 failures.
- **Metrics** (CPU/RAM/requests) in the dashboard.

## Cost (test env)

- 2 × `basic-xxs` instances = ~\$10/month
- DO Spaces: \$5/month (250 GB bucket)
- Goldsky subgraph: free tier
- Total: **~\$15/month** for the test environment

## Troubleshooting

### Build fails with "NEXT_PUBLIC_X is undefined"

Next.js strict env lookup. The variable is missing from either
`.do/app.yaml` (non-secret) or the dashboard secret list (secret).
Add it at BUILD_TIME scope and retry.

### Backend 503 on first calls

First hit pays the cold-start penalty. If it persists, check the
backend log — the most common cause is `DO Spaces non configurato`
from a missing/wrong `DO_SPACES_KEY` or `DO_SPACES_SECRET`.

### Frontend can't reach backend

Confirm the path-based ingress is correct in `.do/app.yaml` (the `/api`
rule MUST come before the `/` rule — first match wins). The frontend's
`NEXT_PUBLIC_BACKEND_URL` is `""` (same-origin), and all calls use
`${BACKEND_URL}/api/...` → resolves to `/api/...` → hits backend.

### "Address … is invalid" in the frontend

One of the `NEXT_PUBLIC_*_ADDRESS` vars is not in EIP-55 checksum
form. Run `cast to-check-sum-address 0x...` locally and update both
`.do/app.yaml` and `.env.local`.

## Related

- `CONTRACTS.md` — chain addresses, subgraph endpoint.
- `CLAUDE.md` → Platform section — architecture overview.
- `platform/subgraph/DEPLOY.md` — Goldsky subgraph redeploy flow.
