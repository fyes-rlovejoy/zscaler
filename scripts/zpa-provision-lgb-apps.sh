#!/usr/bin/env bash
# Idempotent provisioning of lgb ZPA application config (specific-app model):
#   lgb segment group -> lgb server group (dynamic, on lgb-pve connectors) ->
#   app segment(s) -> access rule.
#
# First app: lgb-pve0 (10.1.2.20 / lgb-pve0.corp.jetzero.aero) SSH/HTTP/HTTPS.
# Defined by IP *and* FQDN so it works now (IP) and by name once DNS is registered.
#
# Found-by-name first, so re-running is safe. Reuses scripts/zpa-api.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="$ROOT/scripts/zpa-api.sh"

LGB_PVE_CONNECTOR_GROUP_ID="72058199628316729"   # lgb-pve-zpa-app-con-grp
ACCESS_POLICY_SET_ID="72058199628316677"

find_by_name() {
  "$API" GET "$1" 2>/dev/null | python3 -c '
import sys, json
name = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d.get("list") if isinstance(d, dict) else d
for r in (rows or []):
    if r.get("name") == name:
        print(r.get("id")); break
' "$2"
}

ensure() {
  local label="$1" listp="$2" createp="$3" name="$4" body="$5" id
  id="$(find_by_name "$listp" "$name")"
  if [ -n "$id" ]; then echo "[skip]   $label '$name' exists -> $id" >&2; printf '%s' "$id"; return 0; fi
  id="$("$API" POST "$createp" "$body" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("id"): print(d["id"])
else: sys.stderr.write("CREATE FAILED: " + json.dumps(d)[:400] + "\n"); sys.exit(1)
')"
  echo "[create] $label '$name' -> $id" >&2
  printf '%s' "$id"
}

SEG='/mgmtconfig/v1/admin/customers/{cid}/segmentGroup'
SRV='/mgmtconfig/v1/admin/customers/{cid}/serverGroup'
APP='/mgmtconfig/v1/admin/customers/{cid}/application'
POL_LIST='/mgmtconfig/v1/admin/customers/{cid}/policySet/rules/policyType/ACCESS_POLICY'
POL_CREATE="/mgmtconfig/v1/admin/customers/{cid}/policySet/${ACCESS_POLICY_SET_ID}/rule"

SEGGRP_ID="$(ensure 'segmentGroup' "$SEG" "$SEG" 'lgb-zpa-segment-grp' \
  '{"name":"lgb-zpa-segment-grp","description":"lgb (corp.jetzero.aero) specific app segments","enabled":true}')"

SRVGRP_ID="$(ensure 'serverGroup' "$SRV" "$SRV" 'lgb-zpa-server-grp' \
  '{"name":"lgb-zpa-server-grp","description":"lgb-pve connectors (dynamic discovery)","enabled":true,"dynamicDiscovery":true,"appConnectorGroups":[{"id":"'"$LGB_PVE_CONNECTOR_GROUP_ID"'"}]}')"

PVE0_ID="$(ensure 'application' "$APP" "$APP" 'lgb-pve0' \
  '{"name":"lgb-pve0","description":"SSH/HTTP/HTTPS to lgb-pve0 (10.1.2.20)","enabled":true,"domainNames":["10.1.2.20","lgb-pve0.corp.jetzero.aero"],"tcpPortRange":[{"from":"22","to":"22"},{"from":"80","to":"80"},{"from":"443","to":"443"}],"healthCheckType":"DEFAULT","healthReporting":"ON_ACCESS","bypassType":"NEVER","icmpAccessType":"NONE","segmentGroupId":"'"$SEGGRP_ID"'","serverGroups":[{"id":"'"$SRVGRP_ID"'"}]}')"

RULE_ID="$(ensure 'accessRule' "$POL_LIST" "$POL_CREATE" 'Allow lgb-zpa-segment-grp' \
  '{"name":"Allow lgb-zpa-segment-grp","action":"ALLOW","operator":"AND","conditions":[{"operands":[{"objectType":"APP_GROUP","lhs":"id","rhs":"'"$SEGGRP_ID"'"}]}]}')"

echo
echo "=== lgb ZPA app config ==="
echo "  segmentGroup lgb-zpa-segment-grp = $SEGGRP_ID"
echo "  serverGroup  lgb-zpa-server-grp  = $SRVGRP_ID"
echo "  application  lgb-pve0            = $PVE0_ID"
echo "  accessRule   Allow lgb-...       = $RULE_ID"
