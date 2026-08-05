<#
.SYNOPSIS
    Leaver stage of the JML workflow — offboards a terminated user.

.DESCRIPTION
    Immediately disables sign-in and revokes active sessions, then strips
    licenses and group access, moves the user to a "Leavers-Audit" holding
    group, and stamps a termination date. The object is retained (not deleted)
    for the audit retention window. Order is deliberate: access is cut before
    any cleanup happens.
    Required scopes: User.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All

.PARAMETER InputCsv
    Path to a CSV with columns: UserPrincipalName,TerminationDate,LeaversAuditGroupId

.PARAMETER WhatIf
    Dry run — logs intended actions without making changes.

.EXAMPLE
    ./Leaver.ps1 -InputCsv .\terminations.csv -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path $PSScriptRoot "..\jml-audit-log.csv"

function Write-AuditLog {
    param($User, $Action, $Result)
    [pscustomobject]@{
        Timestamp   = (Get-Date -Format "o")
        User        = $User
        Stage       = "Leaver"
        Action      = $Action
        Result      = $Result
        PerformedBy = $env:USERNAME
    } | Export-Csv -Path $logPath -Append -NoTypeInformation
}

if (-not (Test-Path $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "Directory.ReadWrite.All"

$rows = Import-Csv -Path $InputCsv

foreach ($row in $rows) {
    Write-Host "`n--- Processing leaver: $($row.UserPrincipalName) ---" -ForegroundColor Cyan

    try {
        $user = Get-MgUser -Filter "userPrincipalName eq '$($row.UserPrincipalName)'" -Property Id, AssignedLicenses
        if (-not $user) { throw "User not found: $($row.UserPrincipalName)" }

        # Step 1: disable sign-in — close the door first
        if (-not $WhatIf) { Update-MgUser -UserId $user.Id -AccountEnabled:$false }
        Write-AuditLog -User $row.UserPrincipalName -Action "DisableAccount" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        # Step 2: revoke all active sessions/refresh tokens
        if (-not $WhatIf) { Revoke-MgUserSignInSession -UserId $user.Id }
        Write-AuditLog -User $row.UserPrincipalName -Action "RevokeSessions" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        # Step 3: remove all license assignments
        $skuIds = $user.AssignedLicenses | ForEach-Object { $_.SkuId }
        if ($skuIds -and -not $WhatIf) {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds
        }
        Write-AuditLog -User $row.UserPrincipalName -Action "RemoveLicenses:$($skuIds -join ',')" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        # Step 4: remove from all groups, add to Leavers-Audit holding group
        $memberships = Get-MgUserMemberOf -UserId $user.Id
        foreach ($group in $memberships) {
            if (-not $WhatIf) { Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id }
        }
        Write-AuditLog -User $row.UserPrincipalName -Action "RemovedFromAllGroups:$($memberships.Count)" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        if ($row.LeaversAuditGroupId -and -not $WhatIf) {
            New-MgGroupMember -GroupId $row.LeaversAuditGroupId -DirectoryObjectId $user.Id
        }
        Write-AuditLog -User $row.UserPrincipalName -Action "AddedToLeaversAuditGroup" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        # Step 5: stamp termination date on an extension attribute
        if (-not $WhatIf) {
            Update-MgUser -UserId $user.Id -AdditionalProperties @{ onPremisesExtensionAttributes = @{ extensionAttribute1 = "Terminated:$($row.TerminationDate)" } }
        }
        Write-AuditLog -User $row.UserPrincipalName -Action "StampTerminationDate:$($row.TerminationDate)" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        Write-Host "Leaver complete: $($row.UserPrincipalName). Remember to handle mailbox conversion and OneDrive transfer separately." -ForegroundColor Green
    }
    catch {
        Write-AuditLog -User $row.UserPrincipalName -Action "LeaverProcess" -Result "Failed: $($_.Exception.Message)"
        Write-Warning "Failed to process $($row.UserPrincipalName): $($_.Exception.Message)"
    }
}
