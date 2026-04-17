import "dotenv/config";
import Fastify from "fastify";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { nanoid } from "nanoid";

const PORT = Number(process.env.PORT || 4001);
const HOST = process.env.HOST || "0.0.0.0";

const SPACES_REGION = process.env.DO_SPACES_REGION || "fra1";
const SPACES_BUCKET = process.env.DO_SPACES_BUCKET || "growfi-media";
const SPACES_ENDPOINT =
  process.env.DO_SPACES_ENDPOINT ||
  `https://${SPACES_REGION}.digitaloceanspaces.com`;
const SPACES_PUBLIC_BASE =
  process.env.DO_SPACES_PUBLIC_BASE ||
  `https://${SPACES_BUCKET}.${SPACES_REGION}.digitaloceanspaces.com`;

const s3 = new S3Client({
  endpoint: SPACES_ENDPOINT,
  region: SPACES_REGION,
  credentials: {
    accessKeyId: process.env.DO_SPACES_KEY || "",
    secretAccessKey: process.env.DO_SPACES_SECRET || "",
  },
  forcePathStyle: false,
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

const ALLOWED_IMAGE_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/avif": "avif",
  "image/gif": "gif",
};

app.post("/api/upload", async (req, reply) => {
  if (!process.env.DO_SPACES_KEY || !process.env.DO_SPACES_SECRET) {
    return reply.status(503).send({
      error: "DO Spaces non configurato. Imposta DO_SPACES_KEY e DO_SPACES_SECRET.",
    });
  }

  const data = await req.file();
  if (!data) {
    return reply.status(400).send({ error: "Nessun file caricato" });
  }

  const ext = ALLOWED_IMAGE_TYPES[data.mimetype];
  if (!ext) {
    return reply.status(400).send({
      error: `Tipo file non supportato: ${data.mimetype}`,
    });
  }

  const buffer = await data.toBuffer();
  const key = `campaigns/${nanoid(12)}.${ext}`;

  await s3.send(
    new PutObjectCommand({
      Bucket: SPACES_BUCKET,
      Key: key,
      Body: buffer,
      ContentType: data.mimetype,
      ACL: "public-read",
      CacheControl: "public, max-age=31536000, immutable",
    }),
  );

  return {
    key,
    url: `${SPACES_PUBLIC_BASE}/${key}`,
    size: buffer.length,
    contentType: data.mimetype,
    filename: data.filename,
  };
});

app.post<{
  Body: {
    name: string;
    description: string;
    location: string;
    productType: string;
    imageUrl?: string;
  };
}>("/api/metadata", async (req, reply) => {
  if (!process.env.DO_SPACES_KEY || !process.env.DO_SPACES_SECRET) {
    return reply.status(503).send({ error: "DO Spaces non configurato" });
  }

  const { name, description, location, productType, imageUrl } = req.body;
  if (!name || !description) {
    return reply.status(400).send({ error: "name e description obbligatori" });
  }

  const metadata = {
    name,
    description,
    location,
    productType,
    image: imageUrl ?? null,
    createdAt: Date.now(),
  };

  const key = `metadata/${nanoid(12)}.json`;

  await s3.send(
    new PutObjectCommand({
      Bucket: SPACES_BUCKET,
      Key: key,
      Body: JSON.stringify(metadata, null, 2),
      ContentType: "application/json",
      ACL: "public-read",
      CacheControl: "public, max-age=60",
    }),
  );

  return {
    key,
    url: `${SPACES_PUBLIC_BASE}/${key}`,
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
  .then(() =>
    console.log(`GrowFi backend in ascolto su http://${HOST}:${PORT}`),
  );
