import "dotenv/config";
import { buildApp, buildDefaultDeps } from "./app.js";

const PORT = Number(process.env.PORT || 4001);
const HOST = process.env.HOST || "0.0.0.0";

const app = await buildApp(buildDefaultDeps());

app
  .listen({ port: PORT, host: HOST })
  .then(() =>
    console.log(`GrowFi backend in ascolto su http://${HOST}:${PORT}`),
  );
