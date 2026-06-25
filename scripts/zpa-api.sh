#!/usr/bin/env bash
# Minimal ZPA (Gov) API helper.
#
# Reads API credentials from SSM Parameter Store, signs in via the legacy
# client-credentials flow, and issues an authenticated request. The Gov cloud
# (zpagov.us) uses the legacy API framework (OneAPI/ZIdentity is not supported).
#
# Usage:
#   scripts/zpa-api.sh GET  '/mgmtconfig/v1/admin/customers/{cid}/appConnectorGroup'
#   scripts/zpa-api.sh POST '/mgmtconfig/v1/admin/customers/{cid}/...'  '<json body>'
#
# The literal {cid} in the path is replaced with the customer ID from SSM.
# Output is the raw JSON response on stdout (secrets never printed).
#
# Env overrides: REGION, ZPA_BASE, ZPA_SSM_PREFIX
set -euo pipefail

REGION="${REGION:-us-gov-west-1}"
BASE="${ZPA_BASE:-https://config.zpagov.us}"
PREFIX="${ZPA_SSM_PREFIX:-/zscaler/zpa/api}"

ssm() { aws ssm get-parameter --region "$REGION" --name "$1" ${2:-} --query 'Parameter.Value' --output text; }

METHOD="${1:?usage: zpa-api.sh METHOD PATH [BODY]}"
REQ_PATH="${2:?usage: zpa-api.sh METHOD PATH [BODY]}"
BODY="${3:-}"

CID=$(ssm "$PREFIX/client-id")
CSEC=$(ssm "$PREFIX/client-secret" --with-decryption)
CUST=$(ssm "$PREFIX/customer-id")

# Sign in -> bearer token (token is parsed, never echoed)
SIGNIN=$(curl -s -m 25 -X POST "$BASE/signin" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSEC")
unset CSEC
TOKEN=$(printf '%s' "$SIGNIN" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "ERROR: ZPA signin failed: $(printf '%s' "$SIGNIN" | head -c 300)" >&2
  exit 1
fi

REQ_PATH="${REQ_PATH//\{cid\}/$CUST}"
if [ -n "$BODY" ]; then
  curl -s -m 60 -X "$METHOD" "$BASE$REQ_PATH" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$BODY"
else
  curl -s -m 60 -X "$METHOD" "$BASE$REQ_PATH" -H "Authorization: Bearer $TOKEN"
fi