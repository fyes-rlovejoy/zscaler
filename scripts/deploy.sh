#!/usr/bin/env bash
# Thin wrapper around `aws cloudformation deploy` for the ZPA App Connector stacks.
#
# Usage:
#   ./scripts/deploy.sh network      # deploy/update the subnet stack
#   ./scripts/deploy.sh connectors   # deploy/update the ASG stack
#   ./scripts/deploy.sh validate     # validate both templates
#
# Env overrides:
#   REGION (default us-gov-west-1)
#   NETWORK_STACK   (default zpa-network)
#   CONNECTOR_STACK (default zpa-app-connectors)
set -euo pipefail

REGION="${REGION:-us-gov-west-1}"
NETWORK_STACK="${NETWORK_STACK:-zpa-network}"
CONNECTOR_STACK="${CONNECTOR_STACK:-zpa-app-connectors}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN="$ROOT/cloudformation"

params_to_overrides() {
  # Convert a CFN params JSON file into "Key=Value Key=Value ..." overrides,
  # dropping empty values so optional params fall back to template defaults.
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys, shlex
for p in json.load(open(sys.argv[1])):
    v = p["ParameterValue"]
    if v == "":
        continue
    print(f'{p["ParameterKey"]}={shlex.quote(v)}')
PY
}

deploy_stack() {
  local stack="$1" template="$2" params="$3"
  echo ">> Deploying $stack  ($template)"
  # shellcheck disable=SC2046
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$stack" \
    --template-file "$template" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --tags Project=zscaler-app-connectors ManagedBy=CloudFormation \
    --parameter-overrides $(params_to_overrides "$params")
  echo ">> $stack outputs:"
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
    --query 'Stacks[0].Outputs' --output table
}

case "${1:-}" in
  network)
    deploy_stack "$NETWORK_STACK" "$CFN/01-network.yaml" "$CFN/params/01-network.params.json"
    ;;
  connectors)
    deploy_stack "$CONNECTOR_STACK" "$CFN/02-app-connectors.yaml" "$CFN/params/02-app-connectors.params.json"
    ;;
  validate)
    for t in "$CFN/01-network.yaml" "$CFN/02-app-connectors.yaml"; do
      echo ">> Validating $t"
      aws cloudformation validate-template --region "$REGION" --template-body "file://$t" >/dev/null \
        && echo "   OK"
    done
    ;;
  *)
    echo "Usage: $0 {network|connectors|validate}" >&2
    exit 2
    ;;
esac
