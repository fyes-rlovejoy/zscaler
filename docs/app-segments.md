# ZPA application segments (phase 2b)

How internal apps are published to users through the App Connectors. Created via
`scripts/zpa-provision-gc-apps.sh` (idempotent) against the Gov tenant on
2026-06-25.

## aws-gc — gc.jetzero.aero (this build)

All `gc.jetzero.aero` resources live in the aws-gc environment, so they're
published **by domain** through the `aws-gc-app-con-grp` connectors. Single
environment ⇒ no multi-network ambiguity.

| Object | Name | ID | Detail |
|--------|------|----|--------|
| Segment group | `aws-gc-zpa-segment-grp` | `72058199628316746` | groups the gc app segments |
| Server group | `aws-gc-zpa-server-grp` | `72058199628316747` | `dynamicDiscovery=true`, bound to `aws-gc-app-con-grp` (`72058199628316742`) |
| App segment | `aws-gc-domain` | `72058199628316748` | `*.gc.jetzero.aero`, TCP+UDP 1–65535 — domain-wide reach ("DNS") |
| App segment | `aws-gc-utility-win0-rdp` | `72058199628316749` | `utility-win0.gc.jetzero.aero`, TCP 3389 — RDP |
| Access rule | `Allow aws-gc-zpa-segment-grp` | `72058199628316750` | ALLOW the segment group to all authenticated users (policy set `72058199628316677`) |

The specific `utility-win0` segment coexists with the `*.gc.jetzero.aero`
wildcard — ZPA matches most-specific first, so RDP gets its own segment (tighter
port + independent policy/visibility) while everything else in the domain is
covered by the wildcard.

### DNS
No ZPA-side DNS object is needed: the App Connectors resolve `gc.jetzero.aero`
via the VPC resolver, which forwards to the AWS Managed AD DNS through the
existing Route53 Resolver rule `jetzero-gc-forward` (→ `172.30.1.251`,
`172.30.11.31`). Verified: connector subnet resolves `utility-win0.gc.jetzero.aero`
→ `172.30.1.134`.

### Required AWS firewall change
`utility-win0` (`172.30.1.134`) is in the **TC VPC** (`172.30.0.0/16`), reached
from the connectors over **Transit Gateway** `tgw-001c831e829b71b6f`. Its SG
`tc_prod_sg` (`sg-0cdbe2eabbb0e6418`) did not allow the connector subnets, so we
added inbound TCP 3389 from `172.32.10.192/28` and `172.32.10.208/28` (rules
`sgr-08e655091bf0b8325`, `sgr-0c90166f369db34ad`). `tc_prod_sg` is **not**
managed by our CloudFormation — this is applied via CLI:
```
aws ec2 authorize-security-group-ingress --region us-gov-west-1 --group-id sg-0cdbe2eabbb0e6418 \
  --ip-permissions 'IpProtocol=tcp,FromPort=3389,ToPort=3389,IpRanges=[{CidrIp=172.32.10.192/28,Description=ZPA aws-gc connectors RDP},{CidrIp=172.32.10.208/28,Description=ZPA aws-gc connectors RDP}]'
```
Verified: from the connector subnet, `172.30.1.134:3389` and
`utility-win0.gc.jetzero.aero:3389` are both reachable (OPEN).

## Per-environment publishing strategy

`corp.jetzero.aero` resources exist in **more than one** network, so a single
`*.corp.jetzero.aero` wildcard is avoided (it could only bind to one connector
set, and with the flat TGW, connector selection wouldn't stay local). Instead,
each environment is published by its **own scope** bound to its **local**
connectors:

| Environment | Scope | Server group → connectors | Status |
|-------------|-------|---------------------------|--------|
| aws-lz | `172.17.0.0/16` (by subnet) | `aws-lz-zpa-server-grp` → `aws-lz-zpa-app-con-grp` | exists |
| lgb | `10.1.0.0/16` (by subnet) | `lgb-dcs-grp` → `lgb-pve-zpa-app-con-grp` | **pattern only — not yet created** |
| aws-gc | `*.gc.jetzero.aero` (by domain) | `aws-gc-zpa-server-grp` → `aws-gc-app-con-grp` | created (above) |

## Cleanup (2026-06-25)

Deleted orphaned ZPA getting-started **sample objects** (created 2026-04-29 by the
system-default admin, non-functional):
- App segment `Internal Application` (`*.jetzero.aero`, all ports) — `72058199628316675`
- Empty server group `Server Group` (no connectors) — `72058199628316674`

Kept: `Internal Application Group` segment group (still used by `LGB-DFS1-RDP`)
and its ALLOW policy.

**Still unused, NOT deleted (admin-created placeholders — confirm before removing):**
connector groups `AWS` (`72058199628316697`) and `Sophos` (`72058199628316698`),
and the unused provisioning keys `AWS_Deloitte`, `AWS-Test Key`, `Sophos-FQL`.

## Verify / re-run

```bash
./scripts/zpa-provision-gc-apps.sh          # idempotent — re-running reuses existing objects
# End-user test: on the Zscaler Client Connector, RDP to utility-win0.gc.jetzero.aero
```
