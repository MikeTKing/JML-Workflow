# JML (Joiner–Mover–Leaver) Workflow — Microsoft Entra ID

A documented identity lifecycle process for onboarding, transferring, and offboarding
employees in a Microsoft Entra ID (Azure AD) tenant, backed by PowerShell automation
using the Microsoft Graph SDK.

## Why this exists

Identity lifecycle management is one of the highest-impact, highest-risk processes
in IT operations — a missed offboarding step is a live security gap, and a slow
onboarding blocks a new hire's first day. This project models a lightweight but
auditable JML process suitable for a small-to-mid-size org running Entra ID as its
identity source, without requiring a full IGA product (e.g., SailPoint, Saviynt).

## Scope & assumptions

- **Identity source:** Microsoft Entra ID (cloud-only, no on-prem AD sync)
- **Trigger:** HR/manager submits a request (ticket, form, or CSV row) — this project
  automates the *fulfillment*, not the HR intake system itself
- **Execution model:** IT admin (or a scheduled task/Azure Automation runbook) runs
  the relevant script against a request record
- **Out of scope:** Exchange Online mailbox conversion and OneDrive ownership
  transfer are noted as follow-on steps but not scripted here (separate Graph/Exchange
  permission scopes)

## Required Graph permissions (app or delegated)

| Permission | Purpose |
|---|---|
| `User.ReadWrite.All` | Create, update, disable accounts |
| `Group.ReadWrite.All` | Manage group membership |
| `Directory.ReadWrite.All` | Update org-level attributes |
| `Organization.Read.All` | License SKU lookups |

## Workflow overview

**Joiner** — new hire → provision identity, assign license, place in correct groups,
enable Conditional Access coverage, log the action.

**Mover** — role/department change → reconcile group membership and attributes to
match the new role, without re-creating the identity.

**Leaver** — termination → immediately disable sign-in, revoke active sessions, strip
licenses and group access, retain the object for audit trail, and flag for deletion
after a retention window.

Each stage is driven by a CSV input row (or single-user parameters) so it can run
ad hoc or be scheduled/batched.

## Files

```
jml-workflow/
├── README.md
├── docs/
│   └── workflow-diagram.md      (process diagram, described)
└── scripts/
    ├── Joiner.ps1
    ├── Mover.ps1
    └── Leaver.ps1
```

## Process detail

### 1. Joiner

| Step | Action | Graph cmdlet |
|---|---|---|
| 1 | Create user object with UPN, display name, job title, department, manager, usage location | `New-MgUser` |
| 2 | Force password reset at first sign-in | `-PasswordProfile` |
| 3 | Assign license SKU | `Set-MgUserLicense` |
| 4 | Add to department/role security groups | `New-MgGroupMember` |
| 5 | Set manager relationship | `Set-MgUserManagerByRef` |
| 6 | Write audit log row | local CSV/transcript |

Groups drive downstream access (SaaS app assignment, Conditional Access scope,
distribution lists), so group membership is treated as the primary access control
point rather than one-off permission grants.

### 2. Mover

| Step | Action | Graph cmdlet |
|---|---|---|
| 1 | Read current group memberships | `Get-MgUserMemberOf` |
| 2 | Remove groups tied to old department/role | `Remove-MgGroupMemberByRef` |
| 3 | Add groups tied to new department/role | `New-MgGroupMember` |
| 4 | Update job title, department, manager | `Update-MgUser` |
| 5 | Re-evaluate license (upgrade/downgrade SKU if role requires it) | `Set-MgUserLicense` |
| 6 | Write audit log row | local CSV/transcript |

The script never deletes and recreates the account — same object ID, same
sign-in history, only entitlements change. This matters for audit continuity.

### 3. Leaver

| Step | Action | Graph cmdlet |
|---|---|---|
| 1 | Disable sign-in immediately | `Update-MgUser -AccountEnabled:$false` |
| 2 | Revoke all active sessions/refresh tokens | `Revoke-MgUserSignInSession` |
| 3 | Remove all license assignments | `Set-MgUserLicense` (remove) |
| 4 | Remove from all groups except a "Leavers-Audit" holding group | `Remove-MgGroupMemberByRef` |
| 5 | Add termination date + reason to `employeeLeaveDateTime`/extension attribute | `Update-MgUser` |
| 6 | Write audit log row, flag for deletion after retention window (e.g., 30 days) | local CSV/transcript |

Order matters here: **disable + revoke sessions first**, before touching licenses
or groups — that closes the door immediately, and everything after is cleanup.

### Follow-on steps (manual / separate system)

- Convert mailbox to shared mailbox, set forwarding (Exchange Online)
- Transfer OneDrive/SharePoint ownership to manager
- Remove from any non-Entra SaaS apps not covered by SSO group sync
- Hard-delete the Entra object after the retention window expires

## Logging & audit trail

All three scripts append a row to `jml-audit-log.csv` (user, action, timestamp,
performed-by, result) so every lifecycle event has a record independent of Entra's
own audit log — useful for compliance evidence and for spotting a leaver step that
silently failed.

## Testing notes

Developed and tested against a personal Entra ID tenant lab (Conditional Access
policies, MFA, audit logs already configured) using the Microsoft.Graph PowerShell
SDK in `-WhatIf`-safe dry-run mode before live runs.

## Tested

Validated end-to-end against a live Entra ID lab tenant (GovBec):

- **Joiner** — created a test user, set manager, confirmed department/job title/UPN
  in the Entra admin center
- **Mover** — updated job title and department, confirmed the object ID stayed
  identical before and after (proving the script updates the existing account
  rather than recreating it)
- **Leaver** — disabled sign-in, revoked active sessions, stamped a termination
  date; confirmed all steps logged `Success`
- **Cleanup** — removed the test account, returning the tenant to a clean state

Full audit trail for each stage was captured in `jml-audit-log.csv` throughout,
following the `-WhatIf` dry run → live run pattern described in `TESTING.md` for
every stage. Testing also caught and fixed two logging bugs in `Joiner.ps1`: the
`CreateUser` step was labeling dry runs as `Success` instead of `DryRun`, and a
failure partway through the script was always attributed to `CreateUser` in the
audit log regardless of which step actually failed. Both are fixed in the current
version.
