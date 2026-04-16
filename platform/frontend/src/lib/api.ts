const BACKEND_URL =
  process.env.NEXT_PUBLIC_BACKEND_URL || "http://localhost:4001";

export async function uploadImage(
  file: File,
): Promise<{ cid: string; url: string }> {
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

export async function uploadMetadata(input: {
  name: string;
  description: string;
  location: string;
  productType: string;
  imageCid?: string;
}): Promise<{ cid: string; url: string }> {
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
