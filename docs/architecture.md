# Architecture — ZPA App Connectors in GovCloud

## Traffic model (why this shape)

App Connectors are **outbound-only**. They establish persistent DTLS/TLS tunnels
*from* the connector *to* the Zscaler cloud. Application traffic flows:

```
  user device ──► Zscaler client ──► Zscaler cloud (ZPA) ──► [tunnel] ──► App Connector ──► private app
                                          ▲                                    │
                                          └──────── outbound 443 only ─────────┘
```

Consequences for the AWS design:

- Connectors need **egress** to the internet (to reach the Zscaler cloud) but
  **no ingress** from the internet. → private subnets behind NAT, SG with no
  inbound rules.
- Connectors need to reach the **private applications** they front. Those apps
  live in this VPC (and peered networks like `172.30.0.0/16` "TC", already routed
  on the private RT). → same private route table provides both paths.

## Network placement

```
general-vpc  vpc-09b4dbbf955d7862f   172.32.0.0/20
│
├─ public  172.32.0.0/24 (1a) ── IGW ── NAT GW nat-0830a9934e632a10a
├─ public  172.32.1.0/24 (1b) ── IGW
│
├─ private (general/ctb) ──┐
│                          │ route table: general-rtb-private-us-gov-west-1
│                          │   0.0.0.0/0     → NAT GW   (internet/Zscaler cloud)
│                          │   172.30.0.0/16 → TC VPC   (peered private apps)
│                          │   pl/...        → S3 gateway endpoint
│                          │   172.32.0.0/20 → local
│                          │
├─ NEW: zpa-appconnector-private-1a  172.32.10.192/28 ─┤  (this project)
└─ NEW: zpa-appconnector-private-1b  172.32.10.208/28 ─┘  associated to same RT
```

Both new `/28` subnets are associated with the **existing** private route table,
so they inherit NAT egress + peering + the S3 endpoint with zero new routing.

### CIDR accounting (in the `172.32.10.0/24` block)

| Range | Subnet |
|-------|--------|
| `.0/27` | ctb-private-subnet-1a |
| `.32/27` | ctb-private-subnet-1b |
| `.64/26` | ctb-dev-private-subnet-1a |
| `.128/26` | ctb-dev-private-subnet-1b |
| **`.192/28`** | **zpa-appconnector-private-1a (new)** |
| **`.208/28`** | **zpa-appconnector-private-1b (new)** |
| `.224/28` | free (room for a 3rd AZ if ever needed) |

## Compute

- **Auto Scaling Group**, `desired=2`, spread across the two new subnets → one
  connector per AZ. ASG replaces a connector that fails EC2 health checks.
- **Launch Template** pins the Zscaler Marketplace AMI, `m5.large`, IMDSv2
  required, and an **encrypted gp3** root volume (the raw AMI ships unencrypted).
- **Rolling updates**: `MinInstancesInService=1, MaxBatchSize=1` so an AMI/version
  bump replaces connectors one at a time, never dropping below one live broker.

### Enrollment at boot

The launch-template user-data:
1. Ensures the AWS CLI is present (installs v2 if the appliance lacks it).
2. Reads the **provisioning key** from SSM Parameter Store (SecureString) — with
   retries, since first boot may race DNS/credentials.
3. Writes it to `/opt/zscaler/var/provision_key` and starts `zpa-connector`,
   which enrolls the instance into the ZPA cloud.

The key is **never** baked into the template or launch-template user-data in
plaintext — only the SSM parameter *name* is. See [decisions.md](decisions.md#d6).

## Identity & access

- Instance role: `AmazonSSMManagedInstanceCore` (admin via **SSM Session
  Manager**, no SSH needed) + a tightly scoped inline policy granting
  `ssm:GetParameter` on exactly the provisioning-key parameter and `kms:Decrypt`
  gated by `kms:ViaService = ssm.<region>`.
- Security group: all egress, **zero ingress** by default. Optional break-glass
  SSH (`AllowSshCidr`) creates a single restricted `:22` rule.

## What's intentionally out of scope here

- Creating the ZPA provisioning key (phase 2 — Zscaler API; see
  [zscaler-api.md](zscaler-api.md)).
- Defining the private application segments / access policies in ZPA.
- Connector group naming / latency-based grouping (set in the ZPA portal/API and
  reflected by which provisioning key is used).
