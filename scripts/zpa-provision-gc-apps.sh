#!/usr/bin/env bash
# Idempotent provisioning of the aws-gc ZPA application config:
#   segment group -> server group (bound to aws-gc connectors) ->
#   app segments (*.gc.jetzero.aero wildcard + utility-win0 RDP) -> access rule.
#
# Each object is found-by-name first and reused if present, so re-running is safe.
# Reuses scripts/zpa-api.sh (signs in via SSM creds; {cid} auto-filled).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="$ROOT/scripts/zpa-api.sh"

AWS_GC_CONNECTOR_GROUP_ID="72058199628316742"   # aws-gc-app-con-grp
ACCESS_POLICY_SET_ID="72058199628316677"

# find_by_name LIST_PATH NAME -> prints object id (or nothing)
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

# ensure LABEL LIST_PATH CREATE_PATH NAME JSON_BODY -> prints id (creates if missing)
ensure() {
  local label="$1" listp="$2" createp="$3" name="$4" body="$5" id
  id="$(find_by_name "$listp" "$name")"
  if [ -n "$id" ]; then
    echo "[skip]   $label '$name' already exists -> $id" >&2
    printf '%s' "$id"; return 0
  fi
  id="$("$API" POST "$createp" "$body" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("id"): print(d["id"])
else:
    sys.stderr.write("CREATE FAILED: " + json.dumps(d)[:400] + "\n"); sys.exit(1)
')"
  echo "[create] $label '$name' -> $id" >&2
  printf '%s' "$id"
}

SEG='/mgmtconfig/v1/admin/customers/{cid}/segmentGroup'
SRV='/mgmtconfig/v1/admin/customers/{cid}/serverGroup'
APP='/mgmtconfig/v1/admin/customers/{cid}/application'
POL_LIST='/mgmtconfig/v1/admin/customers/{cid}/policySet/rules/policyType/ACCESS_POLICY'
POL_CREATE="/mgmtconfig/v1/admin/customers/{cid}/policySet/${ACCESS_POLICY_SET_ID}/rule"

# 1. Segment group
SEGGRP_ID="$(ensure 'segmentGroup' "$SEG" "$SEG" 'aws-gc-zpa-segment-grp' \
  '{"name":"aws-gc-zpa-segment-grp","description":"AWS GovCloud (gc.jetzero.aero) app segments","enabled":true}')"

# 2. Server group (dynamic discovery, bound to the aws-gc App Connector group)
SRVGRP_ID="$(ensure 'serverGroup' "$SRV" "$SRV" 'aws-gc-zpa-server-grp' \
  '{"name":"aws-gc-zpa-server-grp","description":"aws-gc connectors","enabled":true,"dynamicDiscovery":true,"appConnectorGroups":[{"id":"'"$AWS_GC_CONNECTOR_GROUP_ID"'"}]}')"

# 3. Wildcard domain app segment (*.gc.jetzero.aero)
DOMAIN_ID="$(ensure 'application' "$APP" "$APP" 'aws-gc-domain' \
  '{"name":"aws-gc-domain","description":"All gc.jetzero.aero resources","enabled":true,"domainNames":["*.gc.jetzero.aero"],"tcpPortRange":[{"from":"1","to":"65535"}],"udpPortRange":[{"from":"1","to":"65535"}],"healthCheckType":"DEFAULT","healthReporting":"ON_ACCESS","bypassType":"NEVER","icmpAccessType":"NONE","segmentGroupId":"'"$SEGGRP_ID"'","serverGroups":[{"id":"'"$SRVGRP_ID"'"}]}')"

# 4. utility-win0 RDP app segment (specific FQDN, TCP 3389)
RDP_ID="$(ensure 'application' "$APP" "$APP" 'aws-gc-utility-win0-rdp' \
  '{"name":"aws-gc-utility-win0-rdp","description":"RDP to utility-win0","enabled":true,"domainNames":["utility-win0.gc.jetzero.aero"],"tcpPortRange":[{"from":"3389","to":"3389"}],"healthCheckType":"DEFAULT","healthReporting":"ON_ACCESS","bypassType":"NEVER","icmpAccessType":"NONE","segmentGroupId":"'"$SEGGRP_ID"'","serverGroups":[{"id":"'"$SRVGRP_ID"'"}]}')"

# 5. Access policy ALLOW rule for the new segment group (all authenticated users)
RULE_ID="$(ensure 'accessRule' "$POL_LIST" "$POL_CREATE" 'Allow aws-gc-zpa-segment-grp' \
  '{"name":"Allow aws-gc-zpa-segment-grp","action":"ALLOW","operator":"AND","conditions":[{"operands":[{"objectType":"APP_GROUP","lhs":"id","rhs":"'"$SEGGRP_ID"'"}]}]}')"

echo
echo "=== aws-gc ZPA app config ==="
echo "  segmentGroup aws-gc-zpa-segment-grp   = $SEGGRP_ID"
echo "  serverGroup  aws-gc-zpa-server-grp    = $SRVGRP_ID"
echo "  application  aws-gc-domain            = $DOMAIN_ID"
echo "  application  aws-gc-utility-win0-rdp  = $RDP_ID"
echo "  accessRule   Allow aws-gc-...         = $RULE_ID"
