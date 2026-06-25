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

## ZPA API basics (CONFIRMED 2026-06-25)

- **Cloud/host:** Gov tenant `zpagov.us` → API base **`https://config.zpagov.us`**
  (GOVUS, legacy API framework; OneAPI/ZIdentity not supported on Gov).
- **Auth:** legacy OAuth2 **client_id + client_secret** → `POST /signin` → bearer
  token. ✅ Verified working (HTTP 200, token received). The value first stored as
  "api key" was the **client_secret**; the separate **client_id** is now stored too.
- **Full endpoint/ID reference:** see [zpa-api-reference.md](zpa-api-reference.md).

## Phase-2 plan (ready to execute)

1. Create App Connector Group **`aws-gc-app-con-grp`** (mirrors the working
   `aws-lz` group; location set for AWS GovCloud us-gov-west-1 / Oregon).
2. Mint a CONNECTOR_GRP provisioning key (enrollment cert `2875`) for that group.
3. Store the key in SSM `/zscaler/zpa/provisioning-key` (SecureString).
4. Scale the ASG to 2 → connectors enroll into the new group.
5. (Later) define application segments + access policies for user apps.
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
