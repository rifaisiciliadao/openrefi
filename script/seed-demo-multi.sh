#!/usr/bin/env bash
# seed-demo-multi.sh — uploads images + metadata for the 2 demo campaigns created
# by MultiCampaignSetup.s.sol. Idempotent. Reads campaign addresses from broadcast file.
#
# Required env (sourced from .env):
#   PRIVATE_KEY                 deployer (also factory owner + producer in the multi setup)
#   RPC_URL                     https://sepolia.base.org
#
# Hardcoded for the v5 (2026-05-07) Sepolia deploy:
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

BACKEND_URL="${BACKEND_URL:-http://localhost:4001}"
RPC_URL="${RPC_URL:-https://sepolia.base.org}"

REGISTRY_ADDRESS="0x9d91b83ba2e068625a42Fe1d375AB1Aa98313584"
PRODUCER_REGISTRY_ADDRESS="0x5d03F9B8F9e01E18C58833dcE0B930f8D7193194"
DEPLOYER_ADDRESS="0xFF6bdef4fB646EE44e29FE8FC0862B02F0Ba8a33"

# Campaigns from the v6 MultiCampaignSetup run.
CAMP_A="0xa4a3b6b7DfD2D4f53B532ba589cae32CB5D17350"
CAMP_B="0xB74eD0B95A14b0b4D0Fe5DaEA031B7BF856C1Dad"

# Image sources.
A_IMG_URL="https://www.visitsicily.info/wp-content/uploads/2022/02/nebrodi.b.5.jpg"
B_IMG_LOCAL="/Users/turinglabs/GIT/@rifaisicilia/website-2.0/public/grapes.jpeg"
PRODUCER_LOGO_PATH="/Users/turinglabs/GIT/@rifaisicilia/website-2.0/public/rifailogo.jpg"

TMP_A=$(mktemp -t growfi-img-A.XXXXXX.jpg)
TMP_B=$(mktemp -t growfi-img-B.XXXXXX.jpg)
TMP_LOGO=$(mktemp -t growfi-logo.XXXXXX.jpg)
trap 'rm -f "$TMP_A" "$TMP_B" "$TMP_LOGO"' EXIT

upload_image() {
  local file="$1"
  local res
  res=$(curl -sS --max-time 60 -X POST "$BACKEND_URL/api/upload" \
    -F "file=@${file};type=image/jpeg")
  echo "$res" | python3 -c 'import sys,json; print(json.load(sys.stdin)["url"])'
}

upload_metadata() {
  local body="$1"
  local res
  res=$(curl -sS --max-time 60 -X POST "$BACKEND_URL/api/metadata" \
    -H "Content-Type: application/json" \
    -d "$body")
  echo "$res" | python3 -c 'import sys,json; print(json.load(sys.stdin)["url"])'
}

upload_producer() {
  local body="$1"
  local res
  res=$(curl -sS --max-time 60 -X POST "$BACKEND_URL/api/producer" \
    -H "Content-Type: application/json" \
    -d "$body")
  echo "$res" | python3 -c 'import sys,json; print(json.load(sys.stdin)["url"])'
}

echo "▸ fetching olive cover (A) → $TMP_A"
curl -sSL --max-time 60 "$A_IMG_URL" -o "$TMP_A"
[ "$(wc -c < "$TMP_A" | tr -d ' ')" -gt 1000 ] || { echo "✗ A image too small"; exit 1; }

echo "▸ copying vineyard cover (B) → $TMP_B"
cp "$B_IMG_LOCAL" "$TMP_B"

echo "▸ uploading A cover"
A_IMG=$(upload_image "$TMP_A")
echo "  ↳ $A_IMG"

echo "▸ uploading B cover"
B_IMG=$(upload_image "$TMP_B")
echo "  ↳ $B_IMG"

echo "▸ uploading producer logo"
cp "$PRODUCER_LOGO_PATH" "$TMP_LOGO"
LOGO_URL=$(upload_image "$TMP_LOGO")
echo "  ↳ $LOGO_URL"

echo "▸ uploading metadata A (Olive)"
A_META=$(upload_metadata "$(cat <<EOF
{
  "name": "Olive IGP Sicily",
  "description": "Productive olive grove in Nebrodi, northern Sicily, certified IGP. Tokenises the future olive harvest under syntropic agroforestry. Investors receive a share of every annual harvest of premium extra-virgin olive oil starting in 2027.",
  "location": "Nebrodi, Sicily, Italy",
  "productType": "olive-oil",
  "imageUrl": "$A_IMG"
}
EOF
)")
echo "  ↳ $A_META"

echo "▸ uploading metadata B (Vineyard)"
B_META=$(upload_metadata "$(cat <<EOF
{
  "name": "Vineyard of Etna",
  "description": "Volcanic-soil vineyard on the southern slope of Mount Etna. Tokenises the future grape harvest, redeemable as bottled Etna DOC red wine starting in 2028. Soils are managed under regenerative practices, no synthetic inputs.",
  "location": "Etna, Catania, Sicily, Italy",
  "productType": "wine",
  "imageUrl": "$B_IMG"
}
EOF
)")
echo "  ↳ $B_META"

echo "▸ setMetadata A on $REGISTRY_ADDRESS"
cast send "$REGISTRY_ADDRESS" \
  "setMetadata(address,string)" "$CAMP_A" "$A_META" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "  ↳ ok"

echo "▸ setMetadata B on $REGISTRY_ADDRESS"
cast send "$REGISTRY_ADDRESS" \
  "setMetadata(address,string)" "$CAMP_B" "$B_META" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "  ↳ ok"

echo "▸ uploading producer profile"
PROFILE_URL=$(upload_producer "$(cat <<EOF
{
  "name": "Rifai Sicilia DAO",
  "bio": "Regenerative-finance host DAO bootstrapping Sicily's first syntropic agroforestry vineyards, olive groves, and citrus orchards onchain.",
  "avatar": "$LOGO_URL",
  "website": "https://rifaisicilia.com",
  "location": "Sicily, Italy"
}
EOF
)")
echo "  ↳ $PROFILE_URL"

echo "▸ setProfile on $PRODUCER_REGISTRY_ADDRESS"
cast send "$PRODUCER_REGISTRY_ADDRESS" \
  "setProfile(string)" "$PROFILE_URL" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "  ↳ ok"

KYC=$(cast call "$PRODUCER_REGISTRY_ADDRESS" "kyced(address)(bool)" "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
if [ "$KYC" != "true" ]; then
  # First grant ourselves the KYC admin role (idempotent — owner can re-grant safely).
  IS_ADMIN=$(cast call "$PRODUCER_REGISTRY_ADDRESS" "isKycAdmin(address)(bool)" "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
  if [ "$IS_ADMIN" != "true" ]; then
    echo "▸ grantKycAdmin(producer)"
    cast send "$PRODUCER_REGISTRY_ADDRESS" \
      "grantKycAdmin(address)" "$DEPLOYER_ADDRESS" \
      --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    echo "  ↳ ok"
  fi
  echo "▸ setKyc(producer, true)"
  cast send "$PRODUCER_REGISTRY_ADDRESS" \
    "setKyc(address,bool)" "$DEPLOYER_ADDRESS" true \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
  echo "  ↳ ok"
else
  echo "▸ KYC already set ✓"
fi

echo
echo "✓ Demo seed complete."
echo "  Olive    : https://sepolia.basescan.org/address/$CAMP_A"
echo "  Vineyard : https://sepolia.basescan.org/address/$CAMP_B"
echo "  meta A   : $A_META"
echo "  meta B   : $B_META"
echo "  profile  : $PROFILE_URL"
