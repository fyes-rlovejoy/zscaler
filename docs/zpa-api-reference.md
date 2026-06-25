# ZPA Gov API — verified reference

Practical, tested reference for **this** tenant (Gov cloud, `zpagov.us`). Endpoints
and IDs below were confirmed live against `config.zpagov.us` on 2026-06-25. Prefer
this over the Zscaler help portal, whose pages are JavaScript-rendered (they don't
archive/scrape cleanly).

## Connection facts

| Item | Value |
|------|-------|
| Cloud | **GOVUS** (admin login `zpagov.us`) — uses the **Legacy API framework** (OneAPI/ZIdentity not supported on Gov) |
| API base host | `https://config.zpagov.us` |
| Auth | `POST /signin`, `Content-Type: application/x-www-form-urlencoded`, body `client_id`,`client_secret` → `{access_token, token_type:"Bearer", expires_in}` |
| Token lifetime | ~3600s; send as `Authorization: Bearer <token>` |
| Customer ID | `72058199628316672` (in resource paths) |
| Credentials | SSM: `/zscaler/zpa/api/{client-id,client-secret,customer-id}` |
| Helper | `scripts/zpa-api.sh METHOD '/path/{cid}/...' [json]` (signs in + calls; `{cid}` auto-filled) |

## Verified endpoints

| Method | Path (under `https://config.zpagov.us`) | Notes |
|--------|------------------------------------------|-------|
| POST | `/signin` | OAuth client-credentials → bearer token |
| GET | `/mgmtconfig/v1/admin/customers/{cid}/appConnectorGroup` | List groups → `{list:[...], totalCount}` |
| GET | `/mgmtconfig/v1/admin/customers/{cid}/appConnectorGroup/{groupId}` | One group (full field set) |
| POST | `/mgmtconfig/v1/admin/customers/{cid}/appConnectorGroup` | Create group |
| GET | `/mgmtconfig/`**`v2`**`/admin/customers/{cid}/enrollmentCert` | ⚠️ **v2 only** — v1 returns `{"exception":"No handler found"}` |
| GET | `/mgmtconfig/v1/admin/customers/{cid}/visible/versionProfiles` | Upgrade/version profiles |
| POST | `/mgmtconfig/v1/admin/customers/{cid}/associationType/CONNECTOR_GRP/provisioningKey` | Mint App Connector provisioning key |

### Response/error conventions
- List endpoints: `{ "list": [...], "totalCount": "N" }` (pagination: `?page=1&pagesize=100`).
- Errors: HTTP 4xx with `{ "exception": "<msg>", "id": "<code>" }` (e.g. `resource.not.found`).

## Known IDs in this tenant (as of 2026-06-25)

**Enrollment certs** (`GET .../v2/.../enrollmentCert`):

| ID | Name |
|----|------|
| 2873 | Root |
| 2874 | Client |
| **2875** | **Connector** ← used to mint App Connector provisioning keys |
| 2876 | Service Edge |
| 2877 | Cloud Controller |

**Version profiles** (`GET .../visible/versionProfiles`):

| ID | Name |
|----|------|
| **0** | Default |
| 72057594037928502 | Previous Default |
| 72057594037928505 | New Release |
| 72057594037928520 | Default - el8 |
| 72057594037928523 | New Release - el8 |
| 72057594037928526 | Previous Default - el8 |
| 72057594037928601 | New Release - el9 |

**Existing App Connector Groups:**

| ID | Name | Connectors |
|----|------|-----------|
| 72058199628316697 | AWS | 0 |
| 72058199628316699 | aws-lz-zpa-app-con-grp | 2 |
| 72058199628316729 | lgb-pve-zpa-app-con-grp | 2 |
| 72058199628316698 | Sophos | 0 |

## App Connector Group — fields (mirrored from working `aws-lz` group)

```json
{
  "name": "aws-gc-app-con-grp",
  "enabled": true,
  "location": "Oregon, USA",
  "latitude": "45.5152",
  "longitude": "-122.6784",
  "countryCode": "US",
  "cityCountry": "Portland, US",
  "dnsQueryType": "IPV4_IPV6",
  "versionProfileId": "0",
  "upgradeDay": "SUNDAY",
  "upgradeTimeInSecs": "66600",
  "overrideVersionProfile": false
}
```

## Provisioning key — fields

```json
{
  "name": "aws-gc-app-con-grp-key",
  "associationType": "CONNECTOR_GRP",
  "enrollmentCertId": "2875",
  "zcomponentId": "<new appConnectorGroup id>",
  "maxUsage": "1000",
  "enabled": true
}
```
The response includes `provisioningKey` (the enrollment token) → store in SSM
`/zscaler/zpa/provisioning-key` (SecureString), which the launch template reads.

## Canonical Zscaler doc URLs (human browsing; JS-rendered)

- Getting started: https://help.zscaler.com/zpa/getting-started-zpa-api
- App Connector Groups API: https://help.zscaler.com/zpa/configuring-app-connector-groups-using-api
- Provisioning keys API: https://help.zscaler.com/zpa/configuring-provisioning-keys-using-api
- Application segments API: https://help.zscaler.com/zpa/configuring-application-segments-using-api
- Terraform provider (cloud names / auth): https://registry.terraform.io/providers/zscaler/zpa/latest/docs
