#!/usr/bin/env bash
# Programmatically download the CrowdStrike FCS CLI via the v2 API endpoint.
# Args:  $1 = FALCON_API_URL  $2 = INSTALL_DIR  $3 = VERSION (optional)
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

BASE_URL="${API_URL#https://}"
BASE_URL="${BASE_URL#http://}"
BASE_URL="${BASE_URL%/}"

SYS=$(uname -s | tr '[:upper:]' '[:lower:]')
MACH=$(uname -m | tr '[:upper:]' '[:lower:]')
case "$SYS" in
  linux)  OS_TAG="linux" ;;
  darwin) OS_TAG="darwin" ;;
  *) echo "Unsupported OS: $SYS"; exit 1 ;;
esac
case "$MACH" in
  x86_64|amd64) ARCH_TAG="amd64" ;;
  aarch64|arm64) ARCH_TAG="arm64" ;;
  *) echo "Unsupported arch: $MACH"; exit 1 ;;
esac
echo "Target platform: ${OS_TAG}/${ARCH_TAG}"

echo "Requesting OAuth token from https://$BASE_URL ..."
TOKEN=$(curl -sS -X POST "https://${BASE_URL}/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${FALCON_CLIENT_ID}&client_secret=${FALCON_CLIENT_SECRET}&grant_type=client_credentials" \
  | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to obtain OAuth token."
  exit 1
fi

if [ -n "$VERSION" ]; then
  FILTER="category:'fcs'+os:'${OS_TAG}'+arch:'${ARCH_TAG}'+file_version:'${VERSION}'"
else
  FILTER="category:'fcs'+os:'${OS_TAG}'+arch:'${ARCH_TAG}'"
fi

ENCODED_FILTER=$(echo "$FILTER" | sed "s/+/%2B/g; s/:/%3A/g; s/'/%27/g")

echo "Querying FCS download API ..."
RESP=$(curl -sS "https://${BASE_URL}/csdownloads/combined/files-download/v2?filter=${ENCODED_FILTER}&limit=100&sort=file_version%7Cdesc" \
  -H "accept: application/json" \
  -H "Authorization: Bearer ${TOKEN}")

if echo "$RESP" | jq -e '.errors[0]' >/dev/null 2>&1; then
  echo "API returned errors:"
  echo "$RESP" | jq -r '.errors[] | "  - \(.message)"'
  exit 1
fi

if ! echo "$RESP" | jq -e '.resources[0]' >/dev/null 2>&1; then
  echo "No resources found in API response"
  echo "$RESP" | jq . 2>/dev/null || echo "$RESP"
  exit 1
fi

DL_URL=$(echo "$RESP" | jq -r '.resources[0].download_info.download_url // empty')
FILE_NAME=$(echo "$RESP" | jq -r '.resources[0].file_name // empty')
FILE_HASH=$(echo "$RESP" | jq -r '.resources[0].download_info.file_hash // .resources[0].file_hash // empty')
FILE_VERSION=$(echo "$RESP" | jq -r '.resources[0].file_version // empty')

if [ -z "$DL_URL" ] || [ -z "$FILE_NAME" ]; then
  echo "Missing download URL or file name"
  exit 1
fi

echo "Found FCS version: ${FILE_VERSION:-unknown}"
echo "File: $FILE_NAME"
echo "Downloading ..."
curl -sSL -o "${TMPDIR}/${FILE_NAME}" "$DL_URL"

if [ -n "$FILE_HASH" ]; then
  ACTUAL=$(sha256sum "${TMPDIR}/${FILE_NAME}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  EXPECTED=$(echo "$FILE_HASH" | tr '[:upper:]' '[:lower:]')
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "SHA mismatch! expected=$EXPECTED actual=$ACTUAL"
    exit 1
  fi
  echo "SHA256 verified."
fi

case "$FILE_NAME" in
  *.tar.gz) tar -xzf "${TMPDIR}/${FILE_NAME}" -C "$TMPDIR" ;;
  *.zip)    unzip -q "${TMPDIR}/${FILE_NAME}" -d "$TMPDIR" ;;
  *) echo "Unsupported archive: $FILE_NAME"; exit 1 ;;
esac

FCS_BIN=$(find "$TMPDIR" -name 'fcs' -o -name 'fcs.exe' | head -n1)
if [ -z "$FCS_BIN" ]; then
  echo "FCS binary not found inside archive"
  exit 1
fi

install -m 0755 "$FCS_BIN" "${INSTALL_DIR}/fcs"
mkdir -p "$HOME/.crowdstrike/log"
echo "Installed: ${INSTALL_DIR}/fcs"
"${INSTALL_DIR}/fcs" --version
