import "dotenv/config";
import { buildApp, buildDefaultDeps } from "./app.js";
import {
  buildMetadataFetcher,
  buildSubgraphFetcher,
  startNotifierLoop,
} from "./notifier.js";

const PORT = Number(process.env.PORT || 4001);
const HOST = process.env.HOST || "0.0.0.0";

const deps = buildDefaultDeps();
const app = await buildApp(deps);

await app.listen({ port: PORT, host: HOST });
console.log(`GrowFi backend in ascolto su http://${HOST}:${PORT}`);

const notifierDisabled = process.env.NOTIFIER_DISABLED === "1";
if (
  !notifierDisabled &&
  deps.notificationStore &&
  deps.email &&
  deps.notificationsUnsubSecret
) {
  const subgraphUrl =
    process.env.SUBGRAPH_URL ||
    "https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/4.0.2/gn";
  const intervalMs = Number(process.env.NOTIFIER_INTERVAL_MS || 10 * 60 * 1000);

  const handle = startNotifierLoop(
    {
      store: deps.notificationStore,
      email: deps.email,
      fetchSubgraph: buildSubgraphFetcher(subgraphUrl),
      fetchMetadata: buildMetadataFetcher(),
      appUrl: deps.appUrl ?? "https://growfi.app",
      unsubSecret: deps.notificationsUnsubSecret,
    },
    {
      intervalMs,
      onResult: (r) => {
        if (r.seeded) {
          app.log.info({ cursor: r.cursor }, "notifier seeded cursors (first run)");
          return;
        }
        if (
          r.scanned.purchases ||
          r.scanned.seasonsEnded ||
          r.scanned.seasonsReported ||
          r.scanned.claimsCommitted ||
          r.notified
        ) {
          app.log.info(
            { scanned: r.scanned, notified: r.notified },
            "notifier digest cycle",
          );
        }
      },
      onError: (err) => app.log.error({ err }, "notifier cycle failed"),
    },
  );

  const shutdown = async () => {
    handle.stop();
    await app.close();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  app.log.info(
    { intervalMs, subgraphUrl },
    "notifier loop started",
  );
} else if (notifierDisabled) {
  app.log.info("notifier disabled via NOTIFIER_DISABLED=1");
}
