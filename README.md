# Zscaler App Connectors — AWS GovCloud

CloudFormation to stand up [Zscaler Private Access (ZPA)](https://www.zscaler.com/products/zscaler-private-access)
**App Connectors** in AWS GovCloud (`us-gov-west-1`), inside the existing
`general-vpc`.

App Connectors are the ZPA data-plane brokers that sit next to your private
applications and build outbound-only tunnels to the Zscaler cloud. Users reach
internal apps through the Zscaler cloud → App Connector path; **no inbound
ports are opened to the connectors**.

## What this deploys

| Layer | Resource | Notes |
|-------|----------|-------|
| Network | 2× `/28` private subnets (one per AZ) | `172.32.10.192/28` (1a), `172.32.10.208/28` (1b) |
| Network | Route table associations | Reuse `general-rtb-private-us-gov-west-1` → NAT egress |
| Compute | Auto Scaling Group (desired=2, spread across both AZs) | Self-healing; one connector per AZ |
| Compute | Launch Template | ZPA App Connector AMI, IMDSv2, encrypted gp3 root |
| Security | Security Group | All egress allowed; **zero ingress** (admin via SSM) |
| Identity | IAM role + instance profile | SSM Session Manager + read provisioning key from SSM |

## Repository layout

```
cloudformation/
  01-network.yaml              # App Connector subnets + RT associations
  02-app-connectors.yaml       # SG, IAM, launch template, ASG
  params/
    01-network.params.json
    02-app-connectors.params.json
scripts/
  deploy.sh                    # thin wrapper around aws cloudformation deploy
docs/
  architecture.md              # network + traffic-flow design
  decisions.md                 # decision log (why each choice was made)
  deployment.md                # step-by-step deploy / rollback runbook
  zscaler-api.md               # phase 2: API enrollment notes (WIP)
```

## Environment (discovered 2026-06-25)

- **Account:** `341370882819` (`aws-us-gov` partition)
- **Region:** `us-gov-west-1` (AZs `us-gov-west-1a`, `us-gov-west-1b`)
- **VPC:** `general-vpc` `vpc-09b4dbbf955d7862f` (`172.32.0.0/20`)
- **Private route table:** `rtb-07aa95919af0e668f` (`0.0.0.0/0` → `nat-0830a9934e632a10a`)
- **App Connector AMI:** `ami-00814956d4ff7ac6c` (`zscaler-pricpa v5.0.3`, x86_64)

## Quick start

```bash
# 1. Network — create the two App Connector subnets
./scripts/deploy.sh network

# 2. App Connectors — SG, IAM, launch template, ASG
#    (requires the ZPA provisioning key in SSM first — see docs/deployment.md)
./scripts/deploy.sh connectors
```

See [`docs/deployment.md`](docs/deployment.md) for the full runbook and
[`docs/decisions.md`](docs/decisions.md) for the rationale behind each choice.

## Status

- [x] Network discovery
- [x] CloudFormation: subnets + ASG/launch template
- [ ] ZPA provisioning key created & stored in SSM (phase 2 — Zscaler API)
- [ ] Connectors enrolled and serving apps
