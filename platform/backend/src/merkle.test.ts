import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { MerkleTree } from "merkletreejs";
import { keccak256, encodePacked, getAddress } from "viem";
import { buildTree, computeLeaf } from "./merkle.js";

const ALICE = getAddress("0xAaaaAaaAAaaAAaAaaAAaaaAaaaaaaAAaaAAaAaAa");
const BOB = getAddress("0xBbbbbbBBbBbbbBBBbbBBbbBbbbbbBBBbbbbBBbBb");
const CAROL = getAddress("0xcCCCCcCcccCCccCCccCcCccccCCccCCCcCCccCCC");

function keccakBuffer(data: Buffer): Buffer {
  return Buffer.from(
    keccak256(("0x" + data.toString("hex")) as `0x${string}`).slice(2),
    "hex",
  );
}

describe("computeLeaf", () => {
  it("matches the exact packing HarvestManager.redeemProduct uses", () => {
    const direct = keccak256(
      encodePacked(
        ["address", "uint256", "uint256"],
        [ALICE, 7n, 123n * 10n ** 18n],
      ),
    );
    const leaf = computeLeaf(ALICE, 7n, 123n * 10n ** 18n);
    assert.equal(leaf, direct);
  });
});

describe("buildTree", () => {
  it("throws on zero leaves", () => {
    assert.throws(() => buildTree(1n, []), /zero leaves/);
  });

  it("returns root + per-user proofs (keyed lowercase)", () => {
    const { root, proofs } = buildTree(1n, [
      { user: ALICE, productAmount: 10n * 10n ** 18n },
      { user: BOB, productAmount: 7n * 10n ** 18n },
      { user: CAROL, productAmount: 3n * 10n ** 18n },
    ]);
    assert.match(root, /^0x[0-9a-f]{64}$/);
    assert.ok(proofs[ALICE.toLowerCase()]);
    assert.ok(proofs[BOB.toLowerCase()]);
    assert.ok(proofs[CAROL.toLowerCase()]);
  });

  it("proofs verify against OpenZeppelin MerkleProof semantics (sortPairs=true)", () => {
    const seasonId = 42n;
    const entries = [
      { user: ALICE, productAmount: 100n * 10n ** 18n },
      { user: BOB, productAmount: 50n * 10n ** 18n },
      { user: CAROL, productAmount: 25n * 10n ** 18n },
    ];
    const { root, proofs } = buildTree(seasonId, entries);

    for (const entry of entries) {
      const leafHex = computeLeaf(entry.user, seasonId, entry.productAmount);
      const leafBuf = Buffer.from(leafHex.slice(2), "hex");
      const proof = proofs[entry.user.toLowerCase()].map((p) =>
        Buffer.from(p.slice(2), "hex"),
      );
      const verified = MerkleTree.verify(
        proof,
        leafBuf,
        Buffer.from(root.slice(2), "hex"),
        keccakBuffer,
        { sortPairs: true },
      );
      assert.ok(verified, `proof did not verify for ${entry.user}`);
    }
  });

  it("rejects tampered productAmount", () => {
    const seasonId = 1n;
    const { root, proofs } = buildTree(seasonId, [
      { user: ALICE, productAmount: 10n ** 18n },
      { user: BOB, productAmount: 2n * 10n ** 18n },
    ]);
    const tampered = computeLeaf(ALICE, seasonId, 999n * 10n ** 18n);
    const proof = proofs[ALICE.toLowerCase()].map((p) =>
      Buffer.from(p.slice(2), "hex"),
    );
    const verified = MerkleTree.verify(
      proof,
      Buffer.from(tampered.slice(2), "hex"),
      Buffer.from(root.slice(2), "hex"),
      keccakBuffer,
      { sortPairs: true },
    );
    assert.equal(verified, false);
  });

  it("single-leaf tree still verifies", () => {
    const seasonId = 9n;
    const { root, proofs } = buildTree(seasonId, [
      { user: ALICE, productAmount: 5n * 10n ** 18n },
    ]);
    const leafHex = computeLeaf(ALICE, seasonId, 5n * 10n ** 18n);
    // For a single-leaf tree, leaf == root, proof is empty.
    assert.equal(root, leafHex);
    assert.deepEqual(proofs[ALICE.toLowerCase()], []);
  });
});
