import "dotenv/config";
import Fastify from "fastify";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import { PinataSDK } from "pinata";

const PORT = Number(process.env.PORT || 4000);
const HOST = process.env.HOST || "0.0.0.0";

const pinata = new PinataSDK({
  pinataJwt: process.env.PINATA_JWT || "",
  pinataGateway: process.env.PINATA_GATEWAY || "gateway.pinata.cloud",
});

const app = Fastify({
  logger: { transport: { target: "pino-pretty" } },
  bodyLimit: 10 * 1024 * 1024,
});

await app.register(cors, { origin: true });
await app.register(multipart, {
  limits: { fileSize: 5 * 1024 * 1024 },
});

app.get("/health", async () => ({ status: "ok", ts: Date.now() }));

app.post("/api/upload", async (req, reply) => {
  if (!process.env.PINATA_JWT) {
    return reply.status(503).send({
      error: "Pinata non configurato. Imposta PINATA_JWT in .env",
    });
  }

  const data = await req.file();
  if (!data) {
    return reply.status(400).send({ error: "Nessun file caricato" });
  }

  if (!data.mimetype.startsWith("image/")) {
    return reply.status(400).send({ error: "Solo immagini accettate" });
  }

  const buffer = await data.toBuffer();
  const file = new File([buffer], data.filename, { type: data.mimetype });

  const result = await pinata.upload.public.file(file);

  return {
    cid: result.cid,
    url: `https://${process.env.PINATA_GATEWAY || "gateway.pinata.cloud"}/ipfs/${result.cid}`,
    size: buffer.length,
    filename: data.filename,
  };
});

app.post<{
  Body: {
    name: string;
    description: string;
    location: string;
    productType: string;
    imageCid?: string;
  };
}>("/api/metadata", async (req, reply) => {
  if (!process.env.PINATA_JWT) {
    return reply.status(503).send({ error: "Pinata non configurato" });
  }

  const { name, description, location, productType, imageCid } = req.body;

  if (!name || !description) {
    return reply.status(400).send({ error: "name e description obbligatori" });
  }

  const metadata = {
    name,
    description,
    location,
    productType,
    image: imageCid ? `ipfs://${imageCid}` : null,
    createdAt: Date.now(),
  };

  const result = await pinata.upload.public.json(metadata);

  return {
    cid: result.cid,
    url: `https://${process.env.PINATA_GATEWAY || "gateway.pinata.cloud"}/ipfs/${result.cid}`,
    metadata,
  };
});

app.setErrorHandler((err, _req, reply) => {
  app.log.error(err);
  reply.status(err.statusCode || 500).send({
    error: err.message || "Errore interno",
  });
});

app
  .listen({ port: PORT, host: HOST })
  .then(() => console.log(`GrowFi backend in ascolto su http://${HOST}:${PORT}`));
