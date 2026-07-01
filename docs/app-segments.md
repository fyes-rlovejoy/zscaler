# ZPA application segments (phase 2b)

How internal apps are published to users through the App Connectors. Created via
`scripts/zpa-provision-gc-apps.sh` (idempotent) against the Gov tenant on
2026-06-25.

## aws-gc — gc.jetzero.aero

All gc apps run on the `aws-gc-app-con-grp` connectors via server group
`aws-gc-zpa-server-grp` (`72058199628316747`, dynamic). Originally published with
a broad `*.gc.jetzero.aero` all-ports wildcard; **restructured 2026-06-30 to
FQDN-based, per access group** (see "AWS GovCloud servers" below for the full
group model). The old `aws-gc-zpa-segment-grp` + `aws-gc-domain` wildcard were
retired; `aws-gc-utility-win0-rdp` (`utility-win0.gc.jetzero.aero:3389`) moved to
the `jz-all-users` group.

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

## lgb — specific apps (corp.jetzero.aero)

We chose **per-app (zero-trust)** for lgb rather than a broad `10.1.0.0/16` subnet
segment. A wide-open subnet behaves like a traditional VPN (reach anything in the
subnet); the per-app model publishes only the exact host+ports needed. `lgb-dcs-grp`
is a *static* server group (single server `lgb-dc1`), so a new **dynamic** server
group was created for these apps.

| Object | Name | ID | Detail |
|--------|------|----|--------|
| Segment group | `lgb-zpa-segment-grp` | `72058199628316751` | |
| Server group | `lgb-zpa-server-grp` | `72058199628316752` | `dynamicDiscovery=true`, bound to `lgb-pve-zpa-app-con-grp` (`72058199628316729`) |
| App segment | `lgb-pve0` | `72058199628316753` | `10.1.2.20` **and** `lgb-pve0.corp.jetzero.aero`, TCP 22/80/443 (user) |
| App segment | `lgb-ad-services` | `72058199628316755` | `corp.jetzero.aero` + `lgb-dc1.corp.jetzero.aero` — AD essential-6: TCP 53/88/135/389/445/464, UDP 53/88/389/464 |
| App segment | `lgb-corp-smb` | `72058199628316756` | **`*.corp.jetzero.aero`** TCP **445** — SMB to any corp file server (DFS targets) |
| App segment | `lgb-dfs1-smb` | `72058199628316761` | exact `lgb-dfs1.corp.jetzero.aero` TCP **445** — DFS namespace server (un-shadows the wildcard) |
| Access rule | `Allow lgb-zpa-segment-grp` | `72058199628316754` | ALLOW to all authenticated users (covers all lgb apps above) |

### FSx ONTAP SMB (`gc-fsxtank0-smb`) — resolved: it was group membership, not the network
`net use \\fsxtank0.gc.jetzero.aero\pub0` failed for an engineer with **error 64**
("network name no longer available"), and `net view` gave **error 53**. We chased
several network theories (SMB Multichannel, MTU, DNS/Kerberos, DC-locator) — **all
wrong.** The definitive diagnosis came from the **ZPA Access Log**, which showed:

```
status:          BRK_MT_SETUP_FAIL_NO_POLICY_FOUND
domain:          fsxtank0.gc.jetzero.aero
applicationName: gc-fsxtank0-smb   (app segment matched)
connectorName:   Unavailable        (never reached a connector)
```

`NO_POLICY_FOUND` = ZPA matched the app segment but **no Access Policy rule
permitted the user**, so the broker closed the flow **before it ever touched a
connector**. Root cause: the user was **not a member of `NX_TC_Security`**, the
Entra group the engineers rule (`...769`) is gated to — so the SAML groups claim
didn't carry it and the rule denied. (Everything the client saw — "can't find",
error 64/53, the odd `100.64.x.x` ping — was downstream of that policy deny; the
`100.64` IP is just ZPA's synthetic IP, i.e. interception working normally.)

**Fix:** add the user to `NX_TC_Security` (and ensure the group is *assigned* to the
Zscaler ZPA app in Entra), then ZCC **Logout → Login** to mint a fresh SAML
assertion. Verified working 2026-06-30. Segment reverted to a clean
`fsxtank0.gc.jetzero.aero:445` (the LIF-IP / all-ports experiments were removed).

See [troubleshooting.md](troubleshooting.md) for the full method and the ZPA
status-code cheat-sheet — **the lesson: read the ZPA Access Log status first;
`BRK_MT_SETUP_FAIL_NO_POLICY_FOUND` is a policy/identity problem, never a network
one.**

### AD / DFS / SMB design notes
- **DFS is a domain-based namespace** (`\\corp.jetzero.aero\…`). The client gets a referral from a DC → namespace server (`lgb-dfs1`) → file target (`lgb-nas0`, `10.1.10.18` *(changes)*). So we publish: `corp.jetzero.aero` + the DC (`lgb-ad-services`) and **all** corp file targets via the **`*.corp.jetzero.aero`:445 wildcard** (`lgb-corp-smb`) — IP-churn-proof, SMB-only (not VPN).
- **Most-specific-match shadowing gotcha (real one we hit):** the DFS referral for `\\corp.jetzero.aero\share` is FQDN (`\\LGB-DFS1.CORP.JETZERO.AERO\Share`), so the namespace server is `lgb-dfs1`. But `lgb-dfs1` already had an **exact-FQDN** segment (`LGB-DFS1-RDP`, 3389 only); ZPA matches the most-specific domain segment, so SMB **445** to `lgb-dfs1` was shadowed out (the `*.corp:445` wildcard is less specific and didn't apply). `lgb-nas0` worked only because it had no exact segment. Fix: an **exact** `lgb-dfs1-smb` (`...761`, `lgb-dfs1.corp.jetzero.aero:445`) in the user group. **Lesson:** if an FQDN has any exact segment, every port you need for that FQDN must be on an exact segment too — the wildcard won't backfill it.
- **DFS short-name referral gotcha:** referrals currently return `\\lgb-nas0\…` (no domain). Fix on the AD side by re-adding the DFS **folder targets** as FQDNs (`\\lgb-nas0.corp.jetzero.aero\…`) and removing the short ones — **no namespace recreation needed**. On **domain-joined** clients the `corp.jetzero.aero` DNS suffix is already appended, so short referrals often resolve to the FQDN and hit the wildcard anyway.
- **DNS search suffix** (for non-domain-joined clients) is a **Zscaler Client Connector** App-Profile setting (ZCC/Mobile portal), *not* a ZPA-API/app-segment setting.
- **NetBIOS `\\jz\` — confirmed not workable, test segment removed.** ZPA has no NetBIOS/WINS path and the bare `jz` single label doesn't resolve (`nslookup jz` = NXDOMAIN), so `\\jz\share` fails even though `\\corp.jetzero.aero\share` works. Standardize users on the FQDN path (push via GPO/login-script drive mapping). Only way to make `\\jz\` resolve would be an AD-DNS **GlobalNames Zone** entry for `jz` → a DC — secondary to just using the FQDN.

### Admin vs user structure (gating staged, not yet enforced)
Structure is now in place so enforcing admin-only later is a **one-line change to a single rule** (add a SAML `groups` condition). There are **no users provisioned** yet, so the open rules expose nothing today.

| Segment group | ID | Apps | Access rule (today) | Later |
|---------------|----|------|---------------------|-------|
| `lgb-zpa-segment-grp` (user) | `72058199628316751` | `lgb-ad-services`, `lgb-corp-smb`, `lgb-dfs1-smb` | `Allow lgb-zpa-segment-grp` (`...754`) — all auth | keep (users) |
| `lgb-admin-zpa-segment-grp` (admin) | `72058199628316758` | `LGB-DFS1-RDP` (3389), `lgb-pve0` (22/80/443), `lgb-dc1-rdp` (3389, `lgb-dc1.corp.jetzero.aero`/`10.1.130.10`), `lgb-winutil0-rdp` (`...774`, 3389, `lgb-winutil0.corp.jetzero.aero` — FQDN only) | `Allow lgb-admin-zpa-segment-grp` (`72058199628316759`) — gated to `zpa-lgb-admin` | ✅ gated |

To enforce admin-only later, add an identity operand to rule `72058199628316759`:
`{"objectType":"SAML","lhs":"72058199628316728","rhs":"<admin Entra group Object ID>"}`.

Notes:
- `lgb-pve0` (Proxmox mgmt) is now in the **admin** group alongside `LGB-DFS1-RDP`.
- **`LGB-DFS1-RDP` fix (2026-06-30):** it was bound to the **static** `lgb-dcs-grp`, whose only server is `lgb-dc1` (`10.1.130.10`) — so RDP to `lgb-dfs1` was actually landing on the **DC**. Rebound to the dynamic `lgb-zpa-server-grp` and added the correct IP **`10.1.130.108`** (`lgb-dfs1`'s real address) to its domains. `lgb-dcs-grp` (`72058199628316733`) + server object `lgb-dc1` (`...734`, `10.1.130.10`) are now **unused** — candidate cleanup (kept in case the lgb team wants a DC static group).
- Moving `LGB-DFS1-RDP` out left the default **`Internal Application Group`** (`72058199628316676`) **empty**. Its rule `Allow Internal Application Group` (`72058199628316678`) still grants `aws-lz-zpa-segment-grp` (`703`), so don't delete the group/rule without first trimming that operand. Candidate for a later tidy-up.

**Defined by IP and FQDN on purpose:** the IP (`10.1.2.20`) works immediately; the
FQDN (`lgb-pve0.corp.jetzero.aero`) starts working once it's registered in the lgb
AD DNS (`lgb-dc1` = `10.1.130.10`) — no rework needed.

> ⚠️ **Unverified from this account** (the lgb network / `lgb-pve` connectors are
> not in this GovCloud account, so unlike gc this couldn't be tested here):
> - whether `lgb-pve0.corp.jetzero.aero` is registered in the lgb DNS;
> - whether the `lgb-pve` connectors can route to `10.1.2.20` and its host firewall
>   allows them on 22/80/443.
> The lgb admin should confirm both.

> ⚠️ **Access scope:** `lgb-pve0` looks like a **Proxmox VE hypervisor** management
> interface (ssh/web). It's currently open to **all authenticated users** to match
> the existing pattern. If it should be **admin-only**, that's the trigger to wire
> Entra group-based policy (SAML `groups` claim, attr `72058199628316728`) and
> re-gate this rule — see "Admin vs user access" below.

## Access gating — Entra groups

Group-scoped via the `Microsoft` USER IdP (`72058199628316717`) **groups** SAML
attribute `72058199628316728` (no SCIM). Rule condition = `(APP_GROUP)` **AND**
`{objectType:SAML, lhs:72058199628316728, rhs:<group Object ID/GUID>}`.

| Rule (segment group) | Entra group (Object ID) | Status |
|----------------------|-------------------------|--------|
| engineers (`gc-engineers-zpa-segment-grp`) | `NX_TC_Security` (`043c783a-9c23-4aac-8ddb-daf1a16a7d9b`) | ✅ gated 2026-06-30 |
| gc-admin (`gc-admin-zpa-segment-grp`) | `zpa-gc-admin` (`a1fac989-d432-41b2-a5a1-155e18b3ad1f`) | ✅ gated 2026-06-30 |
| lgb-admin (`lgb-admin-zpa-segment-grp`) | `zpa-lgb-admin` (`96e38cc3-e263-4edc-b99f-d26245bd9577`) | ✅ gated 2026-06-30 |
| jz-all-users + lgb users (file/AD/DFS) | — (open / all authenticated) | ✅ open by design |

Entra side: set the Zscaler ZPA app's **groups claim** to "Groups assigned to the
application" (avoids the >150-group overage) and **assign** these groups + the
general user population to the app (app assignment = who can use ZPA at all).

> ⚠️ **Gating gotcha (cost us the fsxtank0 saga, 2026-06-30):** for a gated rule to
> match, three things must all be true — (1) the user is a **member** of the Entra
> group, (2) the group is **assigned to the Zscaler ZPA app** (required when the
> claim is scoped to "Groups assigned to the application" — otherwise Entra omits it
> even for members), and (3) the user has **re-authenticated** since the change (ZCC
> Logout → Login) so the new group is in the SAML assertion. Miss any one and the
> rule denies with `BRK_MT_SETUP_FAIL_NO_POLICY_FOUND` — see
> [troubleshooting.md](troubleshooting.md).

## AWS GovCloud servers — gc-admin / engineers / jz-all-users (2026-06-30)

User-group-based access to GovCloud EC2 (general-vpc + TC VPC, reached via the
aws-gc connectors over TGW). **FQDN-based** so name access (`prd` /
`prd.gc.jetzero.aero`) maps to the right group (restructure 2026-06-30; the broad
all-ports wildcard was retired). All bound to `aws-gc-zpa-server-grp` (`...747`).

| Segment group | ID | App segment | Targets | Ports | Access rule (open) |
|---------------|----|-------------|---------|-------|--------------------|
| `gc-admin-zpa-segment-grp` | `...762` | `gc-admin-rdp-ssh` (`...765`) | `172.30.0.0/16` + `172.32.0.0/20` — **by IP** | TCP 22, 3389 | `Allow gc-admin-...` (`...768`) |
| | | `gc-admin-rdp-ssh-byname` (`...770`) | `*.gc.jetzero.aero` — **by name** | TCP 22, 3389 | (same rule) |
| | | `aws-gc-utility-win0-rdp` (`...749`) | `utility-win0.gc.jetzero.aero` (**admin-only**) | TCP 3389 | (same rule) |
| `gc-engineers-zpa-segment-grp` | `...763` | `gc-license-servers` (`...766`) | `tc-glo` / `tc-lic` / `jz-lic`.gc.jetzero.aero | **all** TCP+UDP | `Allow gc-engineers-...` (`...769`) |
| | | `gc-teamcenter` (`...767`) | `prd` / `sandbox` / `dev1` / `acp`.gc.jetzero.aero | TCP 80, 443, 3000, 4544, 8080 | (same rule) |
| | | `gc-fsxtank0-smb` (`...772`) | `fsxtank0.gc.jetzero.aero` (FSx ONTAP SVM SMB LIF `172.30.1.193`) | TCP 445 | (same rule) |
| `jz-all-users-zpa-segment-grp` | `...764` | `gc-ad-services` (`...773`) | `gc.jetzero.aero` + `*.gc.jetzero.aero` — gc AD/DC (Kerberos/LDAP/locator) | TCP 53/88/135/389/464, UDP 53/88/389/464 | `Allow jz-all-users-...` (`...771`) |
| | | *(web / ctb ALBs — pending Tier-4 ports)* | | TBD | |

**Most-specific-match (by design):** gc-admin **by-name** RDP/SSH to the engineer
hosts (prd/sandbox/dev1/acp, tc-glo/tc-lic/jz-lic) and utility-win0 is shadowed by
their exact FQDN segments → admins reach those **by IP** (the CIDR segment); every
other gc host works by name via the `*.gc:22,3389` wildcard.

**Two hard dependencies before any of this passes traffic:**
1. **Target security groups** must allow the connector subnets (`172.32.10.192/28`, `172.32.10.208/28`) on the app ports. The TC-VPC server SGs are **manual (not CloudFormation)** so they're edited directly (drift-free). Done for the engineer servers (2026-06-30): `tc_prod_sg` (PRD/utility-win0) + `tc_test_sg` (ACP/Dev1/Sandbox) = TCP 80/443/3000/4544/8080/3389; `tc_license_sg` (TC-GLO/TC-LIC/jz-lic) = all TCP+UDP. Still pending: gc-admin RDP/SSH to the other ~23 servers, and the general-vpc web servers whose SGs **are** CFN-managed (stacks `kol-server`, `awg-server`, `simplerisk`, `boomi-atom-*` — not in this repo → update there).
2. **Group gating:** the three rules are **open (all-auth)** today; restricting to the `gc-admin` / `engineers` / `jz-all-users` Entra groups needs each group's **Object ID** added as a `SAML` condition (attr `...728`). No users provisioned yet, so open exposes nothing for now.

Pending Tier-4 (ports TBD): Cadenas, capital-essentials, SyndeiaCloudWithRLM,
jetzeroteamworkcloud, licproxy, linux0; web (80/443?) awg-web, kol-web, map-web,
simplerisk; the `ctb-*-frontend-private` internal ALBs.

## Per-environment publishing strategy

`corp.jetzero.aero` resources exist in **more than one** network, so a single
`*.corp.jetzero.aero` wildcard is avoided (it could only bind to one connector
set, and with the flat TGW, connector selection wouldn't stay local). Instead,
each environment is published by its **own scope** bound to its **local**
connectors:

| Environment | Scope | Server group → connectors | Status |
|-------------|-------|---------------------------|--------|
| aws-lz | `172.17.0.0/16` (by subnet, TCP 443/22) | `aws-lz-zpa-server-grp` → `aws-lz-zpa-app-con-grp` | exists |
| lgb | **per-app** (e.g. `lgb-pve0`); broad `10.1.0.0/16` subnet intentionally skipped | `lgb-zpa-server-grp` (dynamic) → `lgb-pve-zpa-app-con-grp` | created (above) |
| aws-gc | `*.gc.jetzero.aero` (by domain) | `aws-gc-zpa-server-grp` → `aws-gc-app-con-grp` | created |

(`10.1.0.0/16`-by-subnet remains a valid option if you later want VPN-style broad
lgb access — best gated to an admin group, not all users.)

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
