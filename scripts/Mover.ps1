<#
.SYNOPSIS
    Mover stage of the JML workflow — reconciles access for a role/department change.

.DESCRIPTION
    Updates job title/department/manager on an existing Entra ID user and reconciles
    group membership from an old role's groups to a new role's groups. Does not
    recreate the user object, preserving sign-in history and object ID.
    Required scopes: User.ReadWrite.All, Group.ReadWrite.All

.PARAMETER InputCsv
    Path to a CSV with columns: UserPrincipalName,NewJobTitle,NewDepartment,
    NewManagerUpn,RemoveGroups (semicolon-separated group object IDs),
    AddGroups (semicolon-separated group object IDs)

.PARAMETER WhatIf
    Dry run — logs intended actions without making changes.

.EXAMPLE
    ./Mover.ps1 -InputCsv .\role-changes.csv -WhatIf
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
        Stage       = "Mover"
        Action      = $Action
        Result      = $Result
        PerformedBy = $env:USERNAME
    } | Export-Csv -Path $logPath -Append -NoTypeInformation
}

if (-not (Test-Path $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All"

$rows = Import-Csv -Path $InputCsv

foreach ($row in $rows) {
    Write-Host "`n--- Processing mover: $($row.UserPrincipalName) ---" -ForegroundColor Cyan

    try {
        $user = Get-MgUser -Filter "userPrincipalName eq '$($row.UserPrincipalName)'"
        if (-not $user) { throw "User not found: $($row.UserPrincipalName)" }

        # Update attributes
        $updateParams = @{}
        if ($row.NewJobTitle)   { $updateParams["JobTitle"]   = $row.NewJobTitle }
        if ($row.NewDepartment) { $updateParams["Department"] = $row.NewDepartment }

        if ($updateParams.Count -gt 0) {
            if (-not $WhatIf) { Update-MgUser -UserId $user.Id -BodyParameter $updateParams }
            Write-AuditLog -User $row.UserPrincipalName -Action "UpdateAttributes:$($updateParams.Keys -join ',')" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
        }

        # Update manager
        if ($row.NewManagerUpn) {
            $manager = Get-MgUser -Filter "userPrincipalName eq '$($row.NewManagerUpn)'"
            if ($manager -and -not $WhatIf) {
                Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
                }
            }
            Write-AuditLog -User $row.UserPrincipalName -Action "SetManager:$($row.NewManagerUpn)" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
        }

        # Remove old-role groups
        if ($row.RemoveGroups) {
            foreach ($groupId in $row.RemoveGroups -split ";") {
                if (-not $WhatIf) { Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $user.Id }
                Write-AuditLog -User $row.UserPrincipalName -Action "RemoveFromGroup:$groupId" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
            }
        }

        # Add new-role groups
        if ($row.AddGroups) {
            foreach ($groupId in $row.AddGroups -split ";") {
                if (-not $WhatIf) { New-MgGroupMember -GroupId $groupId -DirectoryObjectId $user.Id }
                Write-AuditLog -User $row.UserPrincipalName -Action "AddToGroup:$groupId" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
            }
        }

        Write-Host "Mover complete: $($row.UserPrincipalName)" -ForegroundColor Green
    }
    catch {
        Write-AuditLog -User $row.UserPrincipalName -Action "MoverProcess" -Result "Failed: $($_.Exception.Message)"
        Write-Warning "Failed to process $($row.UserPrincipalName): $($_.Exception.Message)"
    }
}
