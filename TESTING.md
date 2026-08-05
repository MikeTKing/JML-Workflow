# Testing guide

Test against a lab/sandbox Entra ID tenant only — never a production tenant.
These scripts create real accounts, assign real licenses, and disable real
sign-in. If you already have a lab tenant (e.g. from prior Entra ID/AD labs),
reuse it here.

## 1. Prerequisites

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns
```

You need a Global Admin (or scoped custom role) account in the lab tenant to
consent to the required scopes the first time `Connect-MgGraph` runs:
`User.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.ReadWrite.All`.

## 2. Set up test fixtures

- One or two **empty security groups** in the lab tenant (no real users in
  them) to use as `Groups` / `AddGroups` / `RemoveGroups` targets
- One existing user to act as **manager** (`ManagerUpn`)
- If your tenant has a free license SKU (e.g. an unused trial), grab its
  `SkuId` with:
  ```powershell
  Get-MgSubscribedSku | Select SkuPartNumber, SkuId
  ```
- A `Leavers-Audit` group to hold offboarded accounts (create one, note its
  object ID)

Update the placeholder values in `samples/new-hires.csv`,
`samples/role-changes.csv`, and `samples/terminations.csv` to match your
tenant's domain, group IDs, and license SKU.

## 3. Dry run first — always

```powershell
./scripts/Joiner.ps1 -InputCsv .\samples\new-hires.csv -WhatIf
```

Confirm:
- No errors connecting/authenticating
- Console output shows the intended actions (`[WhatIf] Would create user with:...`)
- `jml-audit-log.csv` gets rows with `Result = DryRun`
- No user actually appears in the Entra admin center

Do this for all three scripts before running anything live.

## 4. Live test — Joiner

```powershell
./scripts/Joiner.ps1 -InputCsv .\samples\new-hires.csv
```

Verify in the Entra admin center (entra.microsoft.com → Users):
- User exists with the right UPN, job title, department
- Manager is set correctly (Users → *user* → Manager)
- License assigned (Users → *user* → Licenses), if you set one
- Group membership matches (Groups → *group* → Members), if you set any
- `jml-audit-log.csv` has one row per action, all `Result = Success`

Try sign-in with the temp password — should be forced to reset immediately.

## 5. Live test — Mover

Update `role-changes.csv` to reference the user you just created. Run it,
then verify job title/department changed and group membership reflects the
`RemoveGroups`/`AddGroups` swap, without a new object ID being created
(check `Get-MgUser -UserId <upn> | Select Id` before and after — should be
identical).

## 6. Live test — Leaver

Update `terminations.csv` with the same test user. Run it, then verify:
- `AccountEnabled` is `False` (Get-MgUser -UserId <upn> -Property AccountEnabled)
- Sign-in fails immediately (try it, or check `Revoke-MgUserSignInSession` succeeded in the log)
- Licenses removed
- User appears in the `Leavers-Audit` group and no other groups
- Termination date landed in the extension attribute

## 7. Edge cases worth exercising

- Run `Joiner.ps1` against a `UserPrincipalName` that already exists → confirm it fails cleanly and logs `Result = Failed:...` instead of half-creating something
- Run `Mover.ps1` against a UPN that doesn't exist → same check
- Run `Leaver.ps1` twice in a row on the same user → second run should no-op gracefully on license/group removal (already empty) rather than throwing
- Leave `ManagerUpn` blank in a Joiner row → confirm the script skips manager assignment without erroring

## 8. Cleanup

Delete the test user(s) afterward (`Remove-MgUser -UserId <upn>`) and clear
out `jml-audit-log.csv` test rows if you want a clean log for a demo/portfolio
screenshot.
