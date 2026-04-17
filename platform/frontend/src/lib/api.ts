const BACKEND_URL =
  process.env.NEXT_PUBLIC_BACKEND_URL || "http://localhost:4001";

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
