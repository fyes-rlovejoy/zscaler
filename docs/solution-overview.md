# Solution Overview — Zscaler ZPA for JetZero (AWS GovCloud)

End-to-end summary of what was built: Zscaler ZPA App Connectors in AWS GovCloud and
the private applications published through them with per-group access control.
For detail see [architecture.md](architecture.md) (infra), [app-segments.md](app-segments.md)
(apps/policy), [deployment.md](deployment.md) (deploy runbook), [decisions.md](decisions.md)
(ADRs), and [troubleshooting.md](troubleshooting.md).

## Goal

Give JetZero users zero-trust (ZPA) access to internal applications in AWS GovCloud
and other networks (LGB, aws-lz), replacing broad VPN reach with per-app,
per-Entra-group access.

## Environment

| Item | Value |
|------|-------|
| Cloud | AWS GovCloud (`aws-us-gov`), region `us-gov-west-1`, account `341370882819` |
| general-vpc | `vpc-09b4dbbf955d7862f` (`172.32.0.0/20`) — hosts the connectors |
| TC VPC | `172.30.0.0/16` — Teamcenter / license / FSx / gc AD, reached over TGW `tgw-001c831e829b71b6f` |
| ZPA cloud | GOVUS — admin/API base `https://config.zpagov.us`, customer ID `72058199628316672` |
| gc AD | AWS Managed Microsoft AD `gc.jetzero.aero`, DCs `172.30.1.251` / `172.30.11.31` |

## What was built

### 1. Connector infrastructure (CloudFormation — this repo)
- Two `/28` private subnets across 2 AZs in general-vpc (`172.32.10.192/28`,
  `172.32.10.208/28`), on the existing private route table (NAT egress + TC peering).
- ASG (`desired=2`, one connector/AZ) from the ZPA Marketplace AMI; IMDSv2, encrypted
  gp3 root, rolling updates keep ≥1 broker live.
- Boot enrollment pulls the provisioning key from SSM (SecureString); no secrets in
  templates. **Enrollment fix:** `provision_key` must be `chown zscaler:zscaler` +
  `chmod 640` (the connector runs as the `zscaler` user).
- Both connectors **healthy / authenticated** in group `aws-gc-app-con-grp`.

### 2. ZPA service config (via `scripts/zpa-api.sh` + provisioning scripts)
- Connector group `aws-gc-app-con-grp` (`...742`) + provisioning key.
- Server group `aws-gc-zpa-server-grp` (`...747`, dynamic discovery).
- App segments + segment groups + access rules (below).

### 3. Access model — per Entra group, FQDN-based

Segment groups map to user groups; access rules are gated to Entra groups via the
`Microsoft` IdP **groups** SAML claim (attr `72058199628316728`), no SCIM.

| Segment group (ID) | Apps | Entra group (gating) |
|--------------------|------|----------------------|
| `gc-admin` (`...762`) | RDP/SSH to all gc servers (by-IP CIDR + by-name `*.gc:22,3389`), `utility-win0:3389` | `zpa-gc-admin` (`a1fac989-…`) |
| `gc-engineers` (`...763`) | `gc-teamcenter` (80/443/3000/4544/8080), `gc-license-servers` (all ports), `gc-fsxtank0-smb` (445) | `NX_TC_Security` (`043c783a-…`) |
| `jz-all-users` (`...764`) | `gc-ad-services` (gc Kerberos/LDAP/DC-locator for all), `utility-win0` moved out to admin | open / all authenticated |
| `lgb-zpa` (`...751`) / `lgb-admin` (`...758`) | corp AD/DFS/SMB (users); `lgb-pve0`, DC/DFS RDP (admins) | `zpa-lgb-admin` (`96e38cc3-…`) |
| aws-lz | `172.17.0.0/16` by subnet | (existing) |

Design rules that bit us and are now documented:
- **Most-specific-FQDN match / shadowing** — once a host has an exact-FQDN segment,
  every port you need for it must be on an exact segment; the wildcard won't backfill.
- **Publish per environment by local connectors** — no shared `*.corp.jetzero.aero`
  wildcard (corp spans networks).
- **Gating needs membership + app-assignment + re-login** (see troubleshooting.md).

### 4. AWS firewall dependency
Target EC2 **security groups** must allow the connector `/28`s on the app ports. TC-VPC
server SGs are **manual (not CloudFormation)** so edited directly and drift-free; some
general-vpc web-server SGs **are** CFN-managed in other repos (`kol-server`,
`awg-server`, `simplerisk`, `boomi-atom-*`) → update there.

## Operational runbook

- **Add a user to an app** → add them to the matching Entra group **and** ensure the
  group is assigned to the Zscaler ZPA app, then have them ZCC **Logout → Login**.
- **Publish a new app** → app segment (FQDN, min ports) in the right segment group +
  open the target SG to the connector `/28`s + verify from a connector-subnet probe.
- **Access broken?** → **read the ZPA Access Log `status` first** (troubleshooting.md).
- **Re-run provisioning** (idempotent): `./scripts/zpa-provision-gc-apps.sh`.

## Status (2026-06-30)

- ✅ Connectors deployed, enrolled, healthy.
- ✅ gc / lgb / aws-lz app segments published; 3 admin/engineer rules gated to Entra
  groups; engineer SGs opened to connectors.
- ✅ FSx SMB for engineers **working** (root cause was group membership, not network).
- ⏳ Pending: gc-admin SG rules for remaining ~23 servers; Tier-4 apps (web
  awg/kol/map/simplerisk, `ctb-*-frontend-private` ALBs, Cadenas, capital-essentials,
  SyndeiaCloudWithRLM, jetzeroteamworkcloud, licproxy, linux0) — ports TBD.
- 🔧 Follow-ups: **rotate the ZPA API key** (was echoed to a terminal during setup);
  optional centralized "ZPA-access SG + prefix list" to avoid editing many SGs.
