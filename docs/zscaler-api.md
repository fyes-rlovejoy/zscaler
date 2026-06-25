# Phase 2 — Zscaler ZPA API (WIP)

> Status: **not started.** This file scopes the next phase: using the ZPA API to
> create the connector group + provisioning key and define the application
> segments users will connect to. Captured now so the infra phase stays focused.

## What phase 2 needs to produce

1. **A provisioning key** for the App Connector group → stored in SSM at
   `/zscaler/zpa/provisioning-key` (consumed by `02-app-connectors.yaml`).
2. **An App Connector group** the connectors belong to (region/latency aware).
3. **Application segments + access policies** so users can reach internal apps.

## ZPA API basics (to confirm against the tenant)

- **Auth:** OAuth2 client credentials → bearer token. ZPA API base differs by
  cloud; for ZPA the API host is typically `https://config.private.zscaler.com`
  (confirm the correct cloud/host for this **GovCloud-aligned** tenant — ZPA Gov
  may use a different base, e.g. a `.zscalergov.net` cloud).
- **Key objects:**
  - `App Connector Group` — logical grouping of connectors.
  - `Provisioning Key` (type `CONNECTOR_GRP`) — the enrollment token.
  - `Application Segment`, `Segment Group`, `Server Group`, `Access Policy`.

## Open questions for the user (phase 2)

- Which Zscaler **cloud** is the tenant on (commercial vs Gov)? Sets the API base.
- Do we have **API client credentials** (client ID/secret) provisioned in the
  ZPA portal yet?
- Connector **group name** / location strategy?
- First **applications** to expose (hosts/ports, DNS domains)?

## Likely tooling

- Either the official Zscaler Terraform/SDK, or thin `curl`/Python against the
  REST API. Decide once the cloud/host + credentials are confirmed.

_When we pick this up: fill in the exact API base, add a small script to mint the
provisioning key and `put-parameter` it into SSM, then run
`./scripts/deploy.sh connectors`._
