#!/usr/bin/env bash
# Programmatically download the CrowdStrike FCS CLI via the Falcon API.
# Args:  $1 = FALCON_API_URL   $2 = INSTALL_DIR   $3 = VERSION (optional)
# Env:   FALCON_CLIENT_ID, FALCON_CLIENT_SECRET

set -euo pipefail

API_URL="${1:?missing FALCON_API_URL}"
INSTALL_DIR="${2:?missing INSTALL_DIR}"
VERSION="${3:-}"

: "${FALCON_CLIENT_ID:?FALCON_CLIENT_ID must be set}"
: "${FALCON_CLIENT_SECRET:?FALCON_CLIENT_SECRET must be set}"

mkdir -p "$INSTALL_DIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for tool in curl jq tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required"; exit 1; }
done

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in
  Linux)  OS_SLUG="Linux" ;;
  Darwin) OS_SLUG="Darwin" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac
case "$ARCH" in
  x86_64|amd64) ARCH_SLUG="x86_64" ;;
  aarch64|arm64) ARCH_SLUG="arm64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
echo "Target platform: ${OS_SLUG}_${ARCH_SLUG}"

echo "Requesting OAuth token from $API_URL ..."
TOKEN=$(curl -sS -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${FALCON_CLIENT_ID}" \
  --data-urlencode "client_secret=${FALCON_CLIENT_SECRET}" \
  "${API_URL}/oauth2/token" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to obtain OAuth token. Check credentials and region."
  exit 1
fi

echo "Enumerating FCS CLI builds ..."
LIST_RESP=$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
  "${API_URL}/csdownloads/entities/files/v1?file_name=fcs")

BUILDS_JSON=$(echo "$LIST_RESP" | jq -r --arg os "$OS_SLUG" --arg arch "$ARCH_SLUG" '
  .resources // []
  | map(select(.name | test($os + "_" + $arch + "\\.tar\\.gz$")))
')

if [ -n "$VERSION" ]; then
  BUILDS_JSON=$(echo "$BUILDS_JSON" | jq --arg v "$VERSION" 'map(select(.name | contains($v)))')
fi

ASSET=$(echo "$BUILDS_JSON" | jq -r 'sort_by(.created_timestamp) | last // empty')
if [ -z "$ASSET" ] || [ "$ASSET" = "null" ]; then
  echo "No matching FCS CLI build found."
  echo "$LIST_RESP" | jq . || echo "$LIST_RESP"
  exit 1
fi

ASSET_NAME=$(echo "$ASSET" | jq -r '.name')
ASSET_SHA=$(echo "$ASSET"  | jq -r '.sha256 // empty')
echo "Selected: $ASSET_NAME"

echo "Downloading ..."
curl -sS -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/octet-stream" \
  -o "${TMPDIR}/${ASSET_NAME}" \
  "${API_URL}/csdownloads/entities/files/v1?file_name=${ASSET_NAME}"

if [ -n "$ASSET_SHA" ]; then
  ACTUAL=$(sha256sum "${TMPDIR}/${ASSET_NAME}" | awk '{print $1}')
  [ "$ACTUAL" = "$ASSET_SHA" ] || { echo "SHA mismatch"; exit 1; }
  echo "SHA256 verified."
fi

tar -xzf "${TMPDIR}/${ASSET_NAME}" -C "$TMPDIR"
install -m 0755 "${TMPDIR}/fcs" "${INSTALL_DIR}/fcs"
echo "Installed: ${INSTALL_DIR}/fcs"
"${INSTALL_DIR}/fcs" --version
