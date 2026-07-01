# Troubleshooting ZPA private-app access

The single most important lesson from this engagement: **when a private app "won't
connect," read the ZPA Access Log first.** The client-side symptoms (Windows error
64/53, "can't find the network path", pinging a `100.64.x.x` address) are almost
always downstream of a decision ZPA already logged. We burned a lot of time on
network theories for a problem the Access Log named in one field.

## Step 0 — pull the ZPA Access Log for the exact attempt

ZPA Admin Portal → **Analytics → Access Logs** (a.k.a. Diagnostics) → filter by user
+ app/domain, reproduce the failure, read the entry. The fields that matter:

| Field | What it tells you |
|-------|-------------------|
| `status` | the disposition (see cheat-sheet below) — **read this first** |
| `applicationName` / `applicationNames_ids` | which app segment matched (or none) |
| `g_app_grp` | which **segment group** the app is in (→ which access rule should apply) |
| `connectorName` | `Unavailable` = the flow never reached a connector (stopped at the broker/policy) |
| `policyName` / `policyAction` | the access rule that matched (`Unavailable` = none matched) |
| `serverIp` | `Unavailable` = never got as far as picking a backend |

## `status` cheat-sheet

| `status` value | Layer | Meaning / where to look |
|----------------|-------|-------------------------|
| `BRK_MT_SETUP_FAIL_NO_POLICY_FOUND` | **Policy / identity** | App segment matched but **no Access Policy rule allowed this user**. **Not a network problem.** Check group membership + SAML groups claim + rule conditions. |
| `BRK_MT_AUTH_*` / reauth failures | Identity | SAML/reauth issue — assertion expired, IdP problem. |
| `BRK_MT_SETUP_FAIL_NO_ASSISTANT_AVAILABLE` (or connector/`assistant` errors) | Connector | No healthy connector in the server group can serve the app (connector down, or app not reachable from it). |
| `BRK_MT_SETUP_TIMEOUT` / connector-to-server errors | Network | Connector reached but **couldn't reach the backend** — SG/firewall, routing, wrong IP/port. |
| `BRK_MT_...CLOSED` after bytes flowed | App | Connected fine; app-level behavior (auth, protocol). |

Rule of thumb: **`connectorName: Unavailable` ⇒ the problem is broker/policy/identity,
not the connector, backend, DNS, SG, or MTU.** Don't touch the network until the log
shows the flow actually reached a connector.

## Case study — FSx SMB "error 64" was a missing group membership (2026-06-30)

**Symptom:** an engineer's `net use \\fsxtank0.gc.jetzero.aero\pub0` failed with
**error 64** ("network name no longer available"); `net view` gave **error 53**;
`ping` showed a "weird" `100.64.x.x` IP; `klist get cifs/fsxtank0...` hung then said
"target unreachable".

**What we wrongly chased** (all disproven):
- *SMB Multichannel* — the SVM has a single SMB LIF (`172.30.1.193`), nothing to
  multichannel to.
- *MTU / large Kerberos packet* — TCP segments; not the cause.
- *DNS / DC-locator / Kerberos over ZPA* — plausible-sounding, but…
- *Connector can't reach the backend* — disproven directly: from the connector
  subnet, `fsxtank0:445` negotiated SMB fine, and **both** gc DCs answered on 88/389.

**What the Access Log said immediately:**
`status = BRK_MT_SETUP_FAIL_NO_POLICY_FOUND`, `applicationName = gc-fsxtank0-smb`,
`g_app_grp = 72058199628316763` (gc-engineers), `connectorName = Unavailable`.

**Root cause:** the user was **not a member of `NX_TC_Security`**, the Entra group
the engineers rule (`...769`) is gated to. The SAML groups claim therefore didn't
carry it, the rule denied, and ZPA closed the flow at the broker. The `100.64.x.x`
"weird IP" was just ZPA's synthetic interception IP (working as intended).

**Fix:** add the user to `NX_TC_Security`; make sure the group is **assigned to the
Zscaler ZPA app** in Entra (the groups claim is scoped to "Groups assigned to the
application"); **ZCC Logout → Login** to get a fresh assertion. Both Teamcenter and
fsxtank0 (same group, same rule) came back together.

**Tell:** fsxtank0 and Teamcenter are in the *same* segment group behind the *same*
rule — if one is denied by policy, so is the other. When "only SMB is broken but web
works," confirm they're actually under the same rule before assuming it's SMB.

## The three conditions for a gated rule to match

A `groups`-gated Access Policy rule (`APP_GROUP` **AND** `SAML groups = <Object ID>`)
only allows a user when **all three** hold:

1. **Membership** — the user is in the Entra group.
2. **Assignment** — the group is assigned to the Zscaler ZPA Enterprise App (needed
   because the groups claim is scoped to "Groups assigned to the application").
3. **Fresh assertion** — the user re-authenticated (ZCC **Logout → Login**) after 1
   or 2 changed; group membership rides in the SAML assertion minted at login, so a
   plain client *restart* is not enough.

Propagation: directory membership is near-instant, but token/claim refresh can lag a
few minutes (occasionally 15–30). Wait a few minutes, then Logout → Login.

## Connector-side reachability probe (when the log DOES point at the network)

If `status` indicates a connector-to-backend failure, verify from the connector's own
network position with a throwaway instance in the connector subnet
(`subnet-085c421a7cb00abb2`, SG `sg-008f102ef0043d5f1`, SSM instance profile), then
terminate it. Pattern used repeatedly here:

```bash
# resolve + TCP-probe a backend from the connector subnet
getent ahostsv4 <fqdn>
timeout 5 bash -c '</dev/tcp/<ip>/<port>' && echo OPEN || echo BLOCKED
# real SMB negotiate (proves more than a bare TCP check)
smbclient -L //<fqdn> -N
```

Reachable-from-connector + `NO_POLICY_FOUND` in the log = **stop probing the network;
it's policy/identity.**

## Client-side diagnostics (ZCC)

- **☰ / More → Update Policy** — force a fresh pull of app segments (a restart does
  not always re-fetch).
- **☰ / More → Troubleshoot → Export Logs** — the `ztunnel.log` shows per-query
  DNS/app-segment interception decisions.
- **Logout → Login** — the only way to refresh the SAML groups claim.
- A `100.64.x.x` result from `ping <app-fqdn>` is **normal** (ZPA synthetic IP =
  interception working); it is not the bug.
