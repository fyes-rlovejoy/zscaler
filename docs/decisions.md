# Decision log

Chronological record of design decisions and the reasoning behind them, so
future changes are made with the original intent in view.

## D1 — Place connectors in new private subnets, not existing ones
**Decision:** Create two dedicated `/28` private subnets for App Connectors
rather than reusing the general/ctb private subnets.
**Why:** Clean blast-radius and tagging boundary; lets us reason about and
restrict the connector tier independently. Cost is negligible (subnets are free).

## D2 — `/28` subnet size (11 usable IPs per AZ)
**Decision:** `172.32.10.192/28` (1a) + `172.32.10.208/28` (1b).
**Why:** "Small" per the requirement. A handful of connectors per AZ is plenty;
ASG `MaxSize=4` total fits easily. Carved contiguously after the existing
`ctb` subnets in the `172.32.10.0/24` block, leaving `.224/28` for a possible
3rd AZ. **Reversible-ish:** subnet CIDR can't change after creation, but the
stack can be extended with more/larger subnets later.

## D3 — Reuse the existing private route table (NAT egress)
**Decision:** Associate new subnets with `general-rtb-private-us-gov-west-1`
(`rtb-07aa95919af0e668f`) instead of creating a new RT.
**Why:** That RT already provides everything connectors need — `0.0.0.0/0` → NAT
(reach Zscaler cloud), `172.30.0.0/16` → TC VPC (reach peered private apps), and
the S3 gateway endpoint. No new routing to maintain.

## D4 — Auto Scaling Group, desired=2
**Decision:** One ASG spanning both subnets, `desired=2` (one connector per AZ),
`min=2 max=4`, EC2 health checks, rolling updates one-at-a-time.
**Why:** ZPA needs ≥2 connectors for HA. ASG self-heals on instance failure and
makes AMI/version upgrades a controlled rolling replace. Trade-off: replaced
instances enroll as *new* connectors — stale entries are pruned via the ZPA
portal/API in phase 2.

## D5 — Marketplace AMI pinned, IMDSv2, encrypted root
**Decision:** Pin `ami-00814956d4ff7ac6c` (`zscaler-pricpa v5.0.3`) as a
parameter; enforce IMDSv2; override the root volume to **encrypted gp3**.
**Why:** Reproducible deploys; the raw Marketplace AMI ships an unencrypted
`gp2` root, which we don't want in GovCloud. AMI is a parameter so version
upgrades are a one-line change + rolling update.

## D6 — Provisioning key via SSM SecureString, fetched at boot
**Decision:** The ZPA provisioning key lives in SSM Parameter Store
(SecureString). User-data reads it at boot via the instance role; only the
parameter **name** appears in the template. Parameter typed as `String` (not
`AWS::SSM::Parameter::Name`) so infra can deploy before the key exists.
**Why:** Keeps the secret out of the template, launch-template user-data, git,
and CloudFormation history. The instance role can read exactly one parameter.
Note: ZPA provisioning keys are *enrollment tokens* with a max-use count and
expiry (not long-lived secrets), but we still treat them as secrets.
**Alternative rejected:** injecting the key as a `NoEcho` parameter into
user-data — still retrievable via `ec2:DescribeLaunchTemplateVersions` and
on-box, so weaker.

## D7 — Admin via SSM Session Manager, zero inbound by default
**Decision:** No inbound SG rules by default; administration through SSM Session
Manager. Optional `AllowSshCidr` adds a single restricted `:22` rule for
break-glass.
**Why:** Smallest attack surface; no key-pair sprawl; auditable session access.

## D8 — Two stacks (network / compute), cross-stack exports
**Decision:** `01-network.yaml` exports subnet + VPC IDs; `02-app-connectors.yaml`
imports them via `Fn::ImportValue` keyed on the network stack name.
**Why:** Separates the slow-changing network from the iterated compute layer;
lets us update the ASG/launch template without touching subnets. Matches the
user's phased plan (network → connectors → API).

---
_Open items / revisit later:_
- Connector group strategy & naming (phase 2, ZPA portal/API).
- Whether to add CloudWatch agent / log shipping from connectors.
- Confirm `m5.large` sizing against expected user concurrency.
