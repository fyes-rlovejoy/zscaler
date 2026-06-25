# Phase 2 — Zscaler ZPA API (WIP)

> Status: **not started.** This file scopes the next phase: using the ZPA API to
> create the connector group + provisioning key and define the application
> segments users will connect to. Captured now so the infra phase stays focused.

## What phase 2 needs to produce

1. **A provisioning key** for the App Connector group → stored in SSM at
   `/zscaler/zpa/provisioning-key` (consumed by `02-app-connectors.yaml`).
2. **An App Connector group** the connectors belong to (region/latency aware).
3. **Application segments + access policies** so users can reach internal apps.

## Credentials (stored 2026-06-25)

The Zscaler tenant is on the **Gov cloud** (admin login `zpagov.us`). Credentials
live in SSM Parameter Store, `/zscaler/zpa/`:

| Parameter | Type | Notes |
|-----------|------|-------|
| `/zscaler/zpa/api/key` | SecureString | ZPA API key (single string) |
| `/zscaler/zpa/api/customer-id` | String | ZPA customer/tenant ID |
| `/zscaler/zpa/provisioning-key` | *(to create)* | App Connector enrollment key — minted in this phase |

> ⚠️ The API key was exposed in a terminal session while being stored — **rotate
> it** in the ZPA portal once phase 2 is validated and re-store the new value.

## ZPA API basics (to confirm against the tenant)

- **Cloud/host:** Gov tenant (`zpagov.us`). The ZPA **API base host** for Gov is
  *not* the commercial `config.private.zscaler.com` — confirm the Gov config
  host before writing requests.
- **Auth — OPEN:** legacy ZPA API uses OAuth2 **client_id + client_secret** →
  `POST {base}/signin` → bearer token, with the customer ID in resource paths. We
  currently have a **single API key** + customer ID, which doesn't match that
  two-part scheme — need to confirm whether this is a OneAPI/ZIdentity key, a
  client_secret (and where the client_id is), or a standalone key.
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
