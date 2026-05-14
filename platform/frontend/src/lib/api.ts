const BACKEND_URL = process.env.NEXT_PUBLIC_BACKEND_URL ?? "";

export interface UploadResult {
  key: string;
  url: string;
  size: number;
  contentType: string;
  filename: string;
}

export async function uploadImage(file: File): Promise<UploadResult> {
  const form = new FormData();
  form.append("file", file);

  const res = await fetch(`${BACKEND_URL}/api/upload`, {
    method: "POST",
    body: form,
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Upload failed" }));
    throw new Error(err.error || "Upload failed");
  }

  return res.json();
}

export interface MetadataResult {
  key: string;
  url: string;
  metadata: {
    name: string;
    description: string;
    location: string;
    productType: string;
    image: string | null;
    createdAt: number;
  };
}

export async function uploadMetadata(input: {
  name: string;
  description: string;
  location: string;
  productType: string;
  imageUrl?: string;
}): Promise<MetadataResult> {
  const res = await fetch(`${BACKEND_URL}/api/metadata`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Metadata upload failed" }));
    throw new Error(err.error || "Metadata upload failed");
  }

  return res.json();
}

export interface ProducerProfileResult {
  key: string;
  url: string;
  profile: {
    name: string;
    bio: string;
    avatar: string | null;
    cover: string | null;
    website: string | null;
    location: string | null;
    updatedAt: number;
  };
}

export interface MerkleProof {
  user: string;
  yieldAmount: string | null; // 18-dec, exact burn amount the proof was built for
  productAmount: string; // 18-dec
  proof: `0x${string}`[];
}

export async function fetchMerkleProof(
  campaign: string,
  seasonId: string | number | bigint,
  user: string,
): Promise<MerkleProof | null> {
  const res = await fetch(
    `${BACKEND_URL}/api/merkle/${campaign.toLowerCase()}/${seasonId}/${user.toLowerCase()}`,
  );
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Merkle fetch failed: ${res.status}`);
  return res.json();
}

export interface MerkleGenerateResult {
  root: `0x${string}`;
  url: string;
  count: number;
}

export interface SnapshotResult {
  campaign: string;
  seasonId: string;
  stakingVault: string;
  yieldToken: string;
  /** Sum of all holders' yieldAmount (18-dec string). */
  totalYield: string;
  /** Expected season-scoped total from StakingVault.seasonTotalYieldOwed; null if not exposed. */
  seasonTotalYieldOwed: string | null;
  /** Exact reportHarvest denominator: minted YIELD + ended-season accrued/unminted YIELD. */
  redeemableYieldSupply: string | null;
  holders: Array<{ user: string; yieldAmount: string }>;
  notes: string[];
}

export async function fetchSnapshot(
  campaign: string,
  seasonId: string | number | bigint,
): Promise<SnapshotResult> {
  const res = await fetch(
    `${BACKEND_URL}/api/snapshot/${campaign}/${String(seasonId)}`,
  );
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Snapshot failed" }));
    throw new Error(err.error || `Snapshot failed: ${res.status}`);
  }
  return res.json();
}

export async function generateMerkleTree(input: {
  campaign: string;
  seasonId: string | number | bigint;
  totalProductUnits: string;
  totalYieldSupply: string;
  holders: Array<{ user: string; yieldAmount: string }>;
  minProductClaim?: string;
}): Promise<MerkleGenerateResult> {
  const body = {
    ...input,
    seasonId: String(input.seasonId),
  };
  const res = await fetch(`${BACKEND_URL}/api/merkle/generate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Merkle gen failed" }));
    throw new Error(err.error || "Merkle gen failed");
  }
  return res.json();
}

export interface InviteRequestInput {
  email: string;
  ethAddress: string;
  telegram: string;
}

export interface InviteRequestResult {
  ok: boolean;
  status: "pending" | "approved" | "rejected";
  address: string;
  emailDelivered: boolean;
}

export async function requestInvite(
  input: InviteRequestInput,
): Promise<InviteRequestResult> {
  const res = await fetch(`${BACKEND_URL}/api/invite/request`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Invite request failed" }));
    throw new Error(err.error || "Invite request failed");
  }
  return res.json();
}

export type InviteCheckStatus = "none" | "pending" | "approved" | "rejected";

export interface InviteCheckResult {
  status: InviteCheckStatus;
  address?: string;
  email?: string;
  telegram?: string;
}

export async function checkInvite(address: string): Promise<InviteCheckResult> {
  const res = await fetch(
    `${BACKEND_URL}/api/invite/check?address=${encodeURIComponent(address)}`,
  );
  if (!res.ok) {
    return { status: "none" };
  }
  return (await res.json()) as InviteCheckResult;
}

export interface InvestorRequestInput {
  name: string;
  email: string;
  company: string;
  role: string;
  message: string;
  website?: string;
}

export interface InvestorRequestResult {
  ok: boolean;
  emailDelivered: boolean;
}

export async function requestInvestorDemo(
  input: InvestorRequestInput,
): Promise<InvestorRequestResult> {
  const res = await fetch(`${BACKEND_URL}/api/investors/request`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    const err = await res
      .json()
      .catch(() => ({ error: "Investor request failed" }));
    throw new Error(err.error || "Investor request failed");
  }
  return res.json();
}

export interface NotificationStatus {
  optedIn: boolean;
  hasEmail: boolean;
  address?: string;
  updatedAt?: number;
}

export async function getNotificationStatus(
  address: string,
): Promise<NotificationStatus> {
  const res = await fetch(
    `${BACKEND_URL}/api/notifications/me?address=${encodeURIComponent(address)}`,
  );
  if (!res.ok) return { optedIn: false, hasEmail: false };
  return res.json();
}

export interface SaveNotificationInput {
  address: string;
  email: string;
  optedIn: boolean;
  issuedAt: string;
  nonce: string;
  signature: `0x${string}`;
}

export async function saveNotificationSettings(
  input: SaveNotificationInput,
): Promise<NotificationStatus> {
  const res = await fetch(`${BACKEND_URL}/api/notifications/me`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    const err = await res
      .json()
      .catch(() => ({ error: "Failed to save notification settings" }));
    throw new Error(err.error || "Failed to save notification settings");
  }
  return res.json();
}

/**
 * Canonical signed message — MUST match the backend's `buildSignedMessage`
 * line-for-line, otherwise viem's signature recovery yields a different
 * address and the PUT bounces with 401.
 */
export function buildNotificationMessage(p: {
  address: string;
  email: string;
  optedIn: boolean;
  issuedAt: string;
  nonce: string;
}): string {
  return [
    "GrowFi notifications",
    `Address: ${p.address.toLowerCase()}`,
    `Email: ${p.email}`,
    `Opted in: ${p.optedIn ? "true" : "false"}`,
    `Issued: ${p.issuedAt}`,
    `Nonce: ${p.nonce}`,
  ].join("\n");
}

export async function uploadProducerProfile(input: {
  name: string;
  bio: string;
  avatar?: string | null;
  cover?: string | null;
  website?: string | null;
  location?: string | null;
}): Promise<ProducerProfileResult> {
  const res = await fetch(`${BACKEND_URL}/api/producer`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: "Profile upload failed" }));
    throw new Error(err.error || "Profile upload failed");
  }

  return res.json();
}
