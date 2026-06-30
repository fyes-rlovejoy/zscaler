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
| `lgb-admin-zpa-segment-grp` (admin) | `72058199628316758` | `LGB-DFS1-RDP` (3389), `lgb-pve0` (22/80/443), `lgb-dc1-rdp` (3389, `lgb-dc1.corp.jetzero.aero`/`10.1.130.10`) | `Allow lgb-admin-zpa-segment-grp` (`72058199628316759`) — all auth | **add SAML groups = admin Entra group** to rule `...759` |

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

## Admin vs user access (not yet wired)

Pattern available for later: broad access for admins, specific apps for users.
The `Microsoft` USER IdP (`72058199628316717`) already emits a SAML **groups**
claim (attribute `72058199628316728`) — so group-scoped access rules are possible
**without SCIM**. To enable, supply the admin Entra group's claim value (Object ID
by default, or name) and we add a `SAML` condition to the relevant access rule(s).
Entra side: set the Zscaler app's groups claim to "Groups assigned to the
application" to avoid the >150-group overage truncation.

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
