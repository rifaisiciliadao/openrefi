import type { NextConfig } from "next";

/**
 * `standalone` output ships a self-contained `.next/standalone/server.js`
 * with only the runtime deps the app actually imports — much smaller
 * Docker image than copying `node_modules`. Required for DO App Platform
 * deploy (image size ↔ cold-start time).
 */
const nextConfig: NextConfig = {
  output: "standalone",
};

export default nextConfig;
