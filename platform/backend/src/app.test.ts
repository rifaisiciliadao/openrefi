import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import type { FastifyInstance } from "fastify";
import { getAddress } from "viem";
import { PutObjectCommand } from "@aws-sdk/client-s3";
import { buildApp, type AppDeps } from "./app.js";
import type { SnapshotResult } from "./snapshot.js";

const ALICE = getAddress("0xAaaaAaaAAaaAAaAaaAAaaaAaaaaaaAAaaAAaAaAa");
const BOB = getAddress("0xBbbbbbBBbBbbbBBBbbBBbbBbbbbbBBBbbbbBBbBb");
const CAMPAIGN = getAddress("0x1111111111111111111111111111111111111111");
const VAULT = getAddress("0x2222222222222222222222222222222222222222");
const YIELD = getAddress("0x3333333333333333333333333333333333333333");

interface TestHarness {
  app: FastifyInstance;
  puts: PutObjectCommand[];
  snapshotCalls: Array<{ campaign: string; seasonId: bigint }>;
  fetchCalls: string[];
  fetchStub: Map<string, { status: number; body: unknown }>;
  snapshotStub: SnapshotResult | Error | null;
}

async function makeApp(overrides: Partial<AppDeps> = {}): Promise<TestHarness> {
  const puts: PutObjectCommand[] = [];
  const snapshotCalls: Array<{ campaign: string; seasonId: bigint }> = [];
  const fetchCalls: string[] = [];
  const fetchStub = new Map<string, { status: number; body: unknown }>();
  let snapshotStub: SnapshotResult | Error | null = null;

  const harness: TestHarness = {
    app: null as unknown as FastifyInstance,
    puts,
    snapshotCalls,
    fetchCalls,
    fetchStub,
    snapshotStub,
  };

  const app = await buildApp({
    config: {
      spacesBucket: "test-bucket",
      spacesPublicBase: "https://cdn.example/test-bucket",
      hasCredentials: true,
    },
    putObject: async (cmd) => {
      puts.push(cmd);
    },
    snapshot: async (campaign, seasonId) => {
      snapshotCalls.push({ campaign, seasonId });
      if (harness.snapshotStub instanceof Error) throw harness.snapshotStub;
      if (!harness.snapshotStub) throw new Error("no snapshot stub configured");
      return harness.snapshotStub;
    },
    fetchJson: async (url) => {
      fetchCalls.push(url);
      const hit = fetchStub.get(url);
      if (!hit) {
        return new Response(null, { status: 404 });
      }
      return new Response(JSON.stringify(hit.body), {
        status: hit.status,
        headers: { "content-type": "application/json" },
      });
    },
    ...overrides,
  });

  harness.app = app;
  return harness;
}

describe("GET /health", () => {
  it("returns ok", async () => {
    const { app } = await makeApp();
    const res = await app.inject({ method: "GET", url: "/health" });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.status, "ok");
    assert.equal(typeof body.ts, "number");
  });
});

describe("POST /api/upload", () => {
  it("503 when credentials missing", async () => {
    const { app } = await makeApp({
      config: {
        spacesBucket: "x",
        spacesPublicBase: "y",
        hasCredentials: false,
      },
    });
    const boundary = "----b";
    const payload = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.png"\r\nContent-Type: image/png\r\n\r\n`,
      ),
      Buffer.from([0x89, 0x50]),
      Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    const res = await app.inject({
      method: "POST",
      url: "/api/upload",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      payload,
    });
    assert.equal(res.statusCode, 503);
  });

  it("400 when no file", async () => {
    const { app } = await makeApp();
    // Multipart request with no files
    const boundary = "----boundary";
    const res = await app.inject({
      method: "POST",
      url: "/api/upload",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      payload: `--${boundary}\r\nContent-Disposition: form-data; name="foo"\r\n\r\nbar\r\n--${boundary}--\r\n`,
    });
    assert.equal(res.statusCode, 400);
  });

  it("400 on unsupported mimetype", async () => {
    const { app } = await makeApp();
    const boundary = "----b";
    const payload = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="x.txt"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--${boundary}--\r\n`,
      ),
    ]);
    const res = await app.inject({
      method: "POST",
      url: "/api/upload",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      payload,
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /Tipo file non supportato/);
  });

  it("200 on valid png, stores with campaigns/ prefix", async () => {
    const { app, puts } = await makeApp();
    const boundary = "----b";
    const payload = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="cover.png"\r\nContent-Type: image/png\r\n\r\n`,
      ),
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    const res = await app.inject({
      method: "POST",
      url: "/api/upload",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      payload,
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.match(body.key, /^campaigns\/.+\.png$/);
    assert.equal(body.url, `https://cdn.example/test-bucket/${body.key}`);
    assert.equal(body.contentType, "image/png");
    assert.equal(puts.length, 1);
    assert.equal(puts[0].input.Bucket, "test-bucket");
    assert.equal(puts[0].input.ACL, "public-read");
  });
});

describe("POST /api/metadata", () => {
  it("503 without credentials", async () => {
    const { app } = await makeApp({
      config: {
        spacesBucket: "x",
        spacesPublicBase: "y",
        hasCredentials: false,
      },
    });
    const res = await app.inject({
      method: "POST",
      url: "/api/metadata",
      payload: { name: "x", description: "y" },
    });
    assert.equal(res.statusCode, 503);
  });

  it("400 when name or description missing", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/metadata",
      payload: { description: "only desc" },
    });
    assert.equal(res.statusCode, 400);
  });

  it("200 stores JSON under metadata/ prefix", async () => {
    const { app, puts } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/metadata",
      payload: {
        name: "Olive IGP",
        description: "Sicilian olive grove",
        location: "Ragusa, Sicily",
        productType: "Extra virgin olive oil",
        imageUrl: "https://cdn.example/x.png",
      },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.match(body.key, /^metadata\/.+\.json$/);
    assert.equal(body.metadata.name, "Olive IGP");
    assert.equal(body.metadata.image, "https://cdn.example/x.png");
    assert.equal(puts.length, 1);
    assert.equal(puts[0].input.ContentType, "application/json");
  });
});

describe("POST /api/producer", () => {
  it("400 when name missing", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/producer",
      payload: { bio: "x" },
    });
    assert.equal(res.statusCode, 400);
  });

  it("200 stores profile under producers/ prefix with defaults", async () => {
    const { app, puts } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/producer",
      payload: { name: "Azienda Pisciotto" },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.match(body.key, /^producers\/.+\.json$/);
    assert.equal(body.profile.name, "Azienda Pisciotto");
    assert.equal(body.profile.bio, "");
    assert.equal(body.profile.avatar, null);
    assert.equal(puts.length, 1);
  });
});

describe("POST /api/merkle/generate", () => {
  it("400 on empty holders (totalYield=0)", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/merkle/generate",
      payload: {
        campaign: CAMPAIGN,
        seasonId: 1,
        totalProductUnits: "1000000000000000000000",
        holders: [{ user: ALICE, yieldAmount: "0" }],
      },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /totalYield/);
  });

  it("400 when minProductClaim excludes everyone", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/merkle/generate",
      payload: {
        campaign: CAMPAIGN,
        seasonId: 1,
        totalProductUnits: (10n * 10n ** 18n).toString(),
        holders: [
          { user: ALICE, yieldAmount: "1" },
          { user: BOB, yieldAmount: "1" },
        ],
        minProductClaim: (100n * 10n ** 18n).toString(),
      },
    });
    assert.equal(res.statusCode, 400);
  });

  it("200 returns root + persists tree JSON to merkle/<campaign>/<season>.json", async () => {
    const { app, puts } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/merkle/generate",
      payload: {
        campaign: CAMPAIGN,
        seasonId: 3,
        totalProductUnits: (100n * 10n ** 18n).toString(),
        holders: [
          { user: ALICE, yieldAmount: (6n * 10n ** 18n).toString() },
          { user: BOB, yieldAmount: (4n * 10n ** 18n).toString() },
        ],
      },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.match(body.root, /^0x[0-9a-f]{64}$/);
    assert.equal(body.count, 2);
    assert.equal(puts.length, 1);
    assert.equal(
      puts[0].input.Key,
      `merkle/${CAMPAIGN.toLowerCase()}/3.json`,
    );
    const stored = JSON.parse(puts[0].input.Body as string);
    assert.equal(stored.root, body.root);
    assert.equal(stored.leaves.length, 2);
    // Alice: 6/10 * 100e18 = 60e18; Bob: 4/10 * 100e18 = 40e18
    const alice = stored.leaves.find(
      (l: { user: string }) => l.user.toLowerCase() === ALICE.toLowerCase(),
    );
    const bob = stored.leaves.find(
      (l: { user: string }) => l.user.toLowerCase() === BOB.toLowerCase(),
    );
    assert.equal(alice.productAmount, (60n * 10n ** 18n).toString());
    assert.equal(bob.productAmount, (40n * 10n ** 18n).toString());
  });
});

describe("GET /api/merkle/:campaign/:seasonId/:user", () => {
  it("404 when the tree JSON is missing", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "GET",
      url: `/api/merkle/${CAMPAIGN}/1/${ALICE}`,
    });
    assert.equal(res.statusCode, 404);
  });

  it("404 when user not in the tree", async () => {
    const h = await makeApp();
    const treeUrl = `${h.app}`; // placeholder
    const url = `https://cdn.example/test-bucket/merkle/${CAMPAIGN.toLowerCase()}/1.json`;
    h.fetchStub.set(url, {
      status: 200,
      body: {
        leaves: [
          {
            user: BOB,
            productAmount: "1",
            proof: ["0x00"],
          },
        ],
      },
    });
    const res = await h.app.inject({
      method: "GET",
      url: `/api/merkle/${CAMPAIGN}/1/${ALICE}`,
    });
    assert.equal(res.statusCode, 404);
    void treeUrl;
  });

  it("200 returns { user, productAmount, proof } for eligible user", async () => {
    const h = await makeApp();
    const url = `https://cdn.example/test-bucket/merkle/${CAMPAIGN.toLowerCase()}/2.json`;
    h.fetchStub.set(url, {
      status: 200,
      body: {
        leaves: [
          {
            user: ALICE,
            productAmount: "42",
            proof: ["0xdeadbeef"],
          },
        ],
      },
    });
    const res = await h.app.inject({
      method: "GET",
      url: `/api/merkle/${CAMPAIGN}/2/${ALICE}`,
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.user, ALICE);
    assert.equal(body.productAmount, "42");
    assert.deepEqual(body.proof, ["0xdeadbeef"]);
  });
});

describe("GET /api/snapshot/:campaign/:seasonId", () => {
  it("500 when snapshot fn throws", async () => {
    const h = await makeApp();
    h.snapshotStub = new Error("subgraph down");
    const res = await h.app.inject({
      method: "GET",
      url: `/api/snapshot/${CAMPAIGN}/1`,
    });
    assert.equal(res.statusCode, 500);
    assert.match(res.json().error, /subgraph down/);
  });

  it("200 serializes bigint fields to strings", async () => {
    const h = await makeApp();
    h.snapshotStub = {
      campaign: CAMPAIGN,
      seasonId: 7n,
      stakingVault: VAULT,
      yieldToken: YIELD,
      totalYield: 42n * 10n ** 18n,
      seasonTotalYieldOwed: 42n * 10n ** 18n,
      holders: [
        { user: ALICE, yieldAmount: 30n * 10n ** 18n },
        { user: BOB, yieldAmount: 12n * 10n ** 18n },
      ],
      notes: ["ok"],
    };
    const res = await h.app.inject({
      method: "GET",
      url: `/api/snapshot/${CAMPAIGN}/7`,
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.campaign, CAMPAIGN);
    assert.equal(body.seasonId, "7");
    assert.equal(body.totalYield, (42n * 10n ** 18n).toString());
    assert.equal(body.holders.length, 2);
    assert.equal(body.holders[0].yieldAmount, (30n * 10n ** 18n).toString());
    assert.deepEqual(body.notes, ["ok"]);
    assert.deepEqual(h.snapshotCalls, [{ campaign: CAMPAIGN, seasonId: 7n }]);
  });
});

beforeEach(() => {
  // Fastify's logger is disabled when NODE_ENV=test, so nothing to reset.
});
