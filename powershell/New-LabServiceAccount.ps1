<#
.SYNOPSIS
    Creates the OrderDesk service account and grants it the rights an IIS
    app-pool identity needs.

.DESCRIPTION
    For a workgroup VM this creates a LOCAL account. For a domain VM, create
    the account in AD first and run this with -SkipAccountCreation to do only
    the rights and group work.

    Rights granted:
      SeBatchLogonRight   - "Log on as a batch job", what an IIS app pool uses
      SeServiceLogonRight - "Log on as a service", for the Scheduled Task path
      IIS_IUSRS membership - so the worker process can read its content

    The password is prompted for and held as a SecureString. It is never
    written to disk and never echoed.

.PARAMETER SkipAccountCreation
    The account already exists (domain account, or created by hand).

.PARAMETER PasswordNeverExpires
    Set the local account's password to never expire. Convenient for a lab,
    and worth NOT setting if you want failure 1 to arrive on its own.

.EXAMPLE
    .\New-LabServiceAccount.ps1
.EXAMPLE
    .\New-LabServiceAccount.ps1 -SkipAccountCreation   # domain account
#>
[CmdletBinding()]
param(
    [switch]$SkipAccountCreation,
    [switch]$PasswordNeverExpires
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.config.ps1"
Assert-LabAdmin
$cfg = Get-LabConfig

$isLocal = $cfg.ServiceAccount.StartsWith('.\')
$accountName = $cfg.ServiceAccountName
$qualified = if ($isLocal) { "$env:COMPUTERNAME\$accountName" } else { $cfg.ServiceAccount }

Write-LabStep "Service account: $qualified"

#---------------------------------------------------------------------------
# 1. the account itself
#---------------------------------------------------------------------------
if ($SkipAccountCreation) {
    Write-LabInfo 'skipping account creation as requested'
}
elseif (-not $isLocal) {
    Write-LabWarn "$($cfg.ServiceAccount) looks like a domain account."
    Write-LabInfo 'Create it in Active Directory, then re-run with -SkipAccountCreation.'
    Write-LabInfo 'Example (on a DC):'
    Write-LabInfo "  New-ADUser -Name $accountName -SamAccountName $accountName ``"
    Write-LabInfo '      -AccountPassword (Read-Host -AsSecureString) -Enabled $true ``'
    Write-LabInfo '      -PasswordNeverExpires $false -Description "OrderDesk app pool"'
    return
}
else {
    $existing = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabOk "local account $accountName already exists"
    }
    else {
        Write-LabInfo 'Choose a password for the service account.'
        Write-LabInfo 'Write it down: Deploy-LabApp.ps1 and the runbooks will ask for it again.'
        $pwd1 = Read-Host -Prompt '  password        ' -AsSecureString
        $pwd2 = Read-Host -Prompt '  confirm password' -AsSecureString

        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd2)
        try {
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringUni($b1)
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringUni($b2)
            $match = ($p1 -ceq $p2)
            $p1 = $null; $p2 = $null
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        if (-not $match) { throw 'The two passwords do not match.' }

        New-LocalUser -Name $accountName -Password $pwd1 `
            -FullName 'OrderDesk service account' `
            -Description $cfg.ServiceAccountDesc `
            -UserMayNotChangePassword | Out-Null
        Write-LabOk "created local account $accountName"

        if ($PasswordNeverExpires) {
            Set-LocalUser -Name $accountName -PasswordNeverExpires $true
            Write-LabOk 'password set to never expire'
        }
        else {
            Write-LabInfo 'password CAN expire - that is deliberate, it is lab failure 1'
        }
    }
}

#---------------------------------------------------------------------------
# 2. group membership
#---------------------------------------------------------------------------
Write-LabStep 'Group membership'

try {
    $members = Get-LocalGroupMember -Group 'IIS_IUSRS' -ErrorAction Stop
    $already = $members | Where-Object { $_.Name -ieq $qualified }
    if ($already) {
        Write-LabOk 'already a member of IIS_IUSRS'
    }
    else {
        Add-LocalGroupMember -Group 'IIS_IUSRS' -Member $qualified
        Write-LabOk 'added to IIS_IUSRS'
    }
}
catch {
    Write-LabWarn "could not update IIS_IUSRS: $($_.Exception.Message)"
    Write-LabInfo 'IIS_IUSRS exists only once IIS is installed; run Install-LabPrereqs.ps1 first'
}

#---------------------------------------------------------------------------
# 3. user rights, via secedit
#
# There is no built-in cmdlet for granting a privilege, so export the local
# security policy, edit the two lines, and import it back. This is the
# standard dependency-free approach.
#---------------------------------------------------------------------------
Write-LabStep 'User rights assignment'

function Get-LabAccountSid {
    param([Parameter(Mandatory)][string]$Account)
    $nt = New-Object System.Security.Principal.NTAccount($Account)
    return $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Grant-LabUserRight {
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][ValidateSet('SeBatchLogonRight', 'SeServiceLogonRight')]
        [string]$Right
    )

    $sid = Get-LabAccountSid -Account $Account
    $work = Join-Path $env:TEMP ("labrights_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $infExport = Join-Path $work 'export.inf'
    $infImport = Join-Path $work 'import.inf'
    $sdb       = Join-Path $work 'local.sdb'

    try {
        & secedit.exe /export /areas USER_RIGHTS /cfg $infExport /quiet | Out-Null
        if (-not (Test-Path $infExport)) { throw 'secedit export produced no file.' }

        # secedit writes UTF-16LE.
        $lines = Get-Content -Path $infExport -Encoding Unicode
        $line = $lines | Where-Object { $_ -match "^\s*$Right\s*=" }

        if ($line) {
            $current = ($line -split '=', 2)[1].Trim()
            if ($current -split ',' | ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -eq "*$sid" -or $_ -eq $Account }) {
                Write-LabOk "$Right already granted"
                return
            }
            $newLine = "$Right = $current,*$sid"
            $body = $lines -replace [regex]::Escape($line), $newLine
        }
        else {
            # The right is not listed at all; add it to [Privilege Rights].
            $body = @()
            $added = $false
            foreach ($l in $lines) {
                $body += $l
                if ($l -match '^\[Privilege Rights\]' -and -not $added) {
                    $body += "$Right = *$sid"
                    $added = $true
                }
            }
            if (-not $added) { $body += @('[Privilege Rights]', "$Right = *$sid") }
        }

        @('[Unicode]', 'Unicode=yes', '[Version]',
          'signature="$CHICAGO$"', 'Revision=1') +
        ($body | Where-Object { $_ -notmatch '^\[Unicode\]|^Unicode=|^\[Version\]|^signature=|^Revision=' }) |
            Set-Content -Path $infImport -Encoding Unicode

        & secedit.exe /configure /db $sdb /cfg $infImport /areas USER_RIGHTS /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit configure returned $LASTEXITCODE" }
        Write-LabOk "granted $Right"
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($right in @('SeBatchLogonRight', 'SeServiceLogonRight')) {
    try   { Grant-LabUserRight -Account $qualified -Right $right }
    catch { Write-LabFail "could not grant ${right}: $($_.Exception.Message)" }
}

Write-LabInfo 'Verify by hand with: secpol.msc -> Local Policies -> User Rights Assignment'

#---------------------------------------------------------------------------
# 4. what this account is NOT given
#---------------------------------------------------------------------------
Write-LabStep 'Summary'
Write-LabInfo "account            : $qualified"
Write-LabInfo 'groups             : IIS_IUSRS'
Write-LabInfo 'rights             : log on as a batch job, log on as a service'
Write-LabInfo 'NOT an Administrator, NOT a SQL sysadmin - sql\06 grants it the'
Write-LabInfo 'minimum it needs in AppSupportLab, which is what makes failure 4'
Write-LabInfo '(permission denied) reachable without breaking anything else.'
Write-LabInfo ''
Write-LabInfo 'Next:  .\Deploy-LabApp.ps1'
