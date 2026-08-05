<#
.SYNOPSIS
    Joiner stage of the JML workflow — provisions a new Entra ID user.

.DESCRIPTION
    Creates a new Entra ID user, assigns a license, sets manager/department,
    adds the user to role-based groups, and writes an audit log entry.
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups,
              Microsoft.Graph.Identity.DirectoryManagement modules.
    Required scopes: User.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All

.PARAMETER InputCsv
    Path to a CSV with columns: DisplayName,UserPrincipalName,MailNickname,
    JobTitle,Department,ManagerUpn,UsageLocation,LicenseSkuId,Groups (semicolon-separated
    group object IDs)

.PARAMETER WhatIf
    Dry run — logs intended actions without making changes.

.EXAMPLE
    ./Joiner.ps1 -InputCsv .\new-hires.csv -WhatIf
    ./Joiner.ps1 -InputCsv .\new-hires.csv
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
        Stage       = "Joiner"
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
    Write-Host "`n--- Processing joiner: $($row.DisplayName) ---" -ForegroundColor Cyan

    $tempPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 14 | ForEach-Object { [char]$_ })

    $userParams = @{
        DisplayName       = $row.DisplayName
        UserPrincipalName = $row.UserPrincipalName
        MailNickname      = $row.MailNickname
        AccountEnabled    = $true
        JobTitle          = $row.JobTitle
        Department        = $row.Department
        UsageLocation     = $row.UsageLocation
        PasswordProfile   = @{
            Password                      = $tempPassword
            ForceChangePasswordNextSignIn = $true
        }
    }

    $currentAction = "CreateUser"

    try {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would create user with: $($userParams | Out-String)"
            $newUser = [pscustomobject]@{ Id = "dry-run-id" }
        }
        else {
            $newUser = New-MgUser @userParams
        }
        Write-AuditLog -User $row.UserPrincipalName -Action "CreateUser" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })

        # Set manager
        if ($row.ManagerUpn) {
            $currentAction = "SetManager:$($row.ManagerUpn)"
            $manager = Get-MgUser -Filter "userPrincipalName eq '$($row.ManagerUpn)'"
            if ($manager -and -not $WhatIf) {
                Set-MgUserManagerByRef -UserId $newUser.Id -BodyParameter @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
                }
            }
            Write-AuditLog -User $row.UserPrincipalName -Action "SetManager:$($row.ManagerUpn)" -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
        }

        # Assign license
        if ($row.LicenseSkuId) {
            $currentAction = "AssignLicense:$($row.LicenseSkuId)"
            if (-not $WhatIf) {
                Set-MgUserLicense -UserId $newUser.Id -AddLicenses @{SkuId = $row.LicenseSkuId } -RemoveLicenses @()
            }
            Write-AuditLog -User $row.UserPrincipalName -Action $currentAction -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
        }

        # Add to groups
        if ($row.Groups) {
            foreach ($groupId in $row.Groups -split ";") {
                $currentAction = "AddToGroup:$groupId"
                if (-not $WhatIf) {
                    New-MgGroupMember -GroupId $groupId -DirectoryObjectId $newUser.Id
                }
                Write-AuditLog -User $row.UserPrincipalName -Action $currentAction -Result $(if ($WhatIf) { "DryRun" } else { "Success" })
            }
        }

        Write-Host "Joiner complete: $($row.UserPrincipalName)" -ForegroundColor Green
    }
    catch {
        Write-AuditLog -User $row.UserPrincipalName -Action $currentAction -Result "Failed: $($_.Exception.Message)"
        Write-Warning "Failed to process $($row.UserPrincipalName) during $currentAction : $($_.Exception.Message)"
    }
}
