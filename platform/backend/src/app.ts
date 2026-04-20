import Fastify, { type FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { nanoid } from "nanoid";
import { getAddress, type Address } from "viem";
import { buildTree } from "./merkle.js";
import { snapshotSeasonYield, type SnapshotResult } from "./snapshot.js";

export interface AppConfig {
  spacesBucket: string;
  spacesPublicBase: string;
  hasCredentials: boolean;
}

export interface AppDeps {
  config: AppConfig;
  putObject: (cmd: PutObjectCommand) => Promise<unknown>;
  fetchJson?: (url: string) => Promise<Response>;
  snapshot?: (campaign: Address, seasonId: bigint) => Promise<SnapshotResult>;
}

const ALLOWED_IMAGE_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/avif": "avif",
  "image/gif": "gif",
};

export function buildDefaultDeps(): AppDeps {
  const region = process.env.DO_SPACES_REGION || "fra1";
  const bucket = process.env.DO_SPACES_BUCKET || "growfi-media";
  const endpoint =
    process.env.DO_SPACES_ENDPOINT || `https://${region}.digitaloceanspaces.com`;
  const publicBase =
    process.env.DO_SPACES_PUBLIC_BASE ||
    `https://${bucket}.${region}.digitaloceanspaces.com`;

  const s3 = new S3Client({
    endpoint,
    region,
    credentials: {
      accessKeyId: process.env.DO_SPACES_KEY || "",
      secretAccessKey: process.env.DO_SPACES_SECRET || "",
    },
    forcePathStyle: false,
  });

  return {
    config: {
      spacesBucket: bucket,
      spacesPublicBase: publicBase,
      hasCredentials:
        Boolean(process.env.DO_SPACES_KEY) &&
        Boolean(process.env.DO_SPACES_SECRET),
    },
    putObject: (cmd) => s3.send(cmd),
    snapshot: snapshotSeasonYield,
  };
}

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const { config, putObject } = deps;
  const snapshot = deps.snapshot ?? snapshotSeasonYield;
  const fetchJson = deps.fetchJson ?? ((url: string) => fetch(url));

  const app = Fastify({
    logger: process.env.NODE_ENV === "test"
      ? false
      : { transport: { target: "pino-pretty" } },
    bodyLimit: 10 * 1024 * 1024,
  });

  await app.register(cors, { origin: true });
  await app.register(multipart, {
    limits: { fileSize: 5 * 1024 * 1024 },
  });

  app.get("/health", async () => ({ status: "ok", ts: Date.now() }));

  app.post("/api/upload", async (req, reply) => {
    if (!config.hasCredentials) {
      return reply.status(503).send({
        error:
          "DO Spaces non configurato. Imposta DO_SPACES_KEY e DO_SPACES_SECRET.",
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

    await putObject(
      new PutObjectCommand({
        Bucket: config.spacesBucket,
        Key: key,
        Body: buffer,
        ContentType: data.mimetype,
        ACL: "public-read",
        CacheControl: "public, max-age=31536000, immutable",
      }),
    );

    return {
      key,
      url: `${config.spacesPublicBase}/${key}`,
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
    if (!config.hasCredentials) {
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

    await putObject(
      new PutObjectCommand({
        Bucket: config.spacesBucket,
        Key: key,
        Body: JSON.stringify(metadata, null, 2),
        ContentType: "application/json",
        ACL: "public-read",
        CacheControl: "public, max-age=60",
      }),
    );

    return {
      key,
      url: `${config.spacesPublicBase}/${key}`,
      metadata,
    };
  });

  app.post<{
    Body: {
      name: string;
      bio: string;
      avatar?: string | null;
      cover?: string | null;
      website?: string | null;
      location?: string | null;
    };
  }>("/api/producer", async (req, reply) => {
    if (!config.hasCredentials) {
      return reply.status(503).send({ error: "DO Spaces non configurato" });
    }

    const { name, bio, avatar, cover, website, location } = req.body;
    if (!name) {
      return reply.status(400).send({ error: "name obbligatorio" });
    }

    const profile = {
      name,
      bio: bio ?? "",
      avatar: avatar ?? null,
      cover: cover ?? null,
      website: website ?? null,
      location: location ?? null,
      updatedAt: Date.now(),
    };

    const key = `producers/${nanoid(12)}.json`;

    await putObject(
      new PutObjectCommand({
        Bucket: config.spacesBucket,
        Key: key,
        Body: JSON.stringify(profile, null, 2),
        ContentType: "application/json",
        ACL: "public-read",
        CacheControl: "public, max-age=60",
      }),
    );

    return {
      key,
      url: `${config.spacesPublicBase}/${key}`,
      profile,
    };
  });

  app.get<{
    Params: { campaign: string; seasonId: string };
  }>("/api/snapshot/:campaign/:seasonId", async (req, reply) => {
    const { campaign, seasonId } = req.params;
    try {
      const snap = await snapshot(
        getAddress(campaign),
        BigInt(seasonId),
      );
      return {
        campaign: snap.campaign,
        seasonId: snap.seasonId.toString(),
        stakingVault: snap.stakingVault,
        yieldToken: snap.yieldToken,
        totalYield: snap.totalYield.toString(),
        seasonTotalYieldOwed: snap.seasonTotalYieldOwed?.toString() ?? null,
        holders: snap.holders.map((h) => ({
          user: h.user,
          yieldAmount: h.yieldAmount.toString(),
        })),
        notes: snap.notes,
      };
    } catch (err) {
      return reply.status(500).send({
        error: err instanceof Error ? err.message : String(err),
      });
    }
  });

  app.post<{
    Body: {
      campaign: string;
      seasonId: string | number;
      totalProductUnits: string;
      holders: Array<{ user: string; yieldAmount: string }>;
      minProductClaim?: string;
    };
  }>("/api/merkle/generate", async (req, reply) => {
    if (!config.hasCredentials) {
      return reply.status(503).send({ error: "DO Spaces non configurato" });
    }

    const { campaign, seasonId, totalProductUnits, holders, minProductClaim } =
      req.body;
    if (!campaign || seasonId === undefined || !totalProductUnits || !holders) {
      return reply.status(400).send({ error: "campos requeridos" });
    }

    const campaignAddr = getAddress(campaign);
    const seasonIdBig = BigInt(seasonId);
    const totalUnits = BigInt(totalProductUnits);
    const minClaim = BigInt(minProductClaim ?? "0");

    const totalYield = holders.reduce(
      (acc, h) => acc + BigInt(h.yieldAmount),
      0n,
    );
    if (totalYield === 0n) {
      return reply.status(400).send({ error: "totalYield is zero" });
    }

    const leaves = holders
      .map((h) => {
        const productAmount = (BigInt(h.yieldAmount) * totalUnits) / totalYield;
        return {
          user: getAddress(h.user) as Address,
          productAmount,
        };
      })
      .filter((l) => l.productAmount >= minClaim);

    if (leaves.length === 0) {
      return reply
        .status(400)
        .send({ error: "no holders above minProductClaim" });
    }

    const { root, proofs } = buildTree(seasonIdBig, leaves);

    const key = `merkle/${campaignAddr.toLowerCase()}/${seasonIdBig}.json`;
    const payload = {
      campaign: campaignAddr,
      seasonId: seasonIdBig.toString(),
      totalProductUnits: totalUnits.toString(),
      root,
      leaves: leaves.map((l) => ({
        user: l.user,
        productAmount: l.productAmount.toString(),
        proof: proofs[l.user.toLowerCase()],
      })),
      generatedAt: Date.now(),
    };

    await putObject(
      new PutObjectCommand({
        Bucket: config.spacesBucket,
        Key: key,
        Body: JSON.stringify(payload, null, 2),
        ContentType: "application/json",
        ACL: "public-read",
        CacheControl: "public, max-age=86400",
      }),
    );

    return {
      root,
      url: `${config.spacesPublicBase}/${key}`,
      count: leaves.length,
    };
  });

  app.get<{
    Params: { campaign: string; seasonId: string; user: string };
  }>("/api/merkle/:campaign/:seasonId/:user", async (req, reply) => {
    const { campaign, seasonId, user } = req.params;
    const url = `${config.spacesPublicBase}/merkle/${campaign.toLowerCase()}/${seasonId}.json`;

    const res = await fetchJson(url);
    if (!res.ok) {
      return reply.status(404).send({ error: "Merkle tree not found", url });
    }
    const payload = (await res.json()) as {
      leaves: Array<{ user: string; productAmount: string; proof: string[] }>;
    };

    const match = payload.leaves.find(
      (l) => l.user.toLowerCase() === user.toLowerCase(),
    );
    if (!match) {
      return reply.status(404).send({
        error: "User not eligible for product redemption this season",
      });
    }

    return {
      user: getAddress(match.user),
      productAmount: match.productAmount,
      proof: match.proof,
    };
  });

  app.setErrorHandler((err, _req, reply) => {
    app.log.error(err);
    reply.status(err.statusCode || 500).send({
      error: err.message || "Errore interno",
    });
  });

  return app;
}
