<#
.SYNOPSIS
    Breaks the OrderDesk lab on purpose, one failure at a time.

.DESCRIPTION
    Each scenario records what it changed in a state file, so Invoke-LabFix.ps1
    can put it back and so you can tell afterwards what was actually done.

    Scenarios:
      BadServiceAccountPassword  rotates the account password WITHOUT updating
                                 the app pool, so the pool cannot start its
                                 worker. Runbook 01.
      StoppedAppPool             stops the app pool (optionally crash-loops it
                                 so rapid-fail protection stops it for you).
                                 Runbook 02.
      BadConnectionString        points the app at an instance that is not
                                 there. Runbook 03.
      PermissionDenied           revokes SELECT on app.Orders from the app's
                                 SQL role. Runbook 04.
      All                        all four, in that order.

    Run this ONLY on a lab VM. It deliberately degrades the service.

.PARAMETER Scenario
    Which failure to inject.

.PARAMETER Confirm2
    Required for -Scenario All, as a small speed bump.

.PARAMETER CrashLoop
    StoppedAppPool only: instead of a clean stop, make the worker fail to
    start repeatedly so rapid-fail protection disables the pool. Closer to
    what you meet in the field.

.EXAMPLE
    .\Invoke-LabBreak.ps1 -Scenario BadServiceAccountPassword
.EXAMPLE
    .\Invoke-LabBreak.ps1 -Scenario StoppedAppPool -CrashLoop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('BadServiceAccountPassword', 'StoppedAppPool',
                 'BadConnectionString', 'PermissionDenied', 'All')]
    [string]$Scenario,

    [switch]$Confirm2,
    [switch]$CrashLoop
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.config.ps1"
Assert-LabAdmin
$cfg = Get-LabConfig
Import-Module WebAdministration -ErrorAction Stop

if ($Scenario -eq 'All' -and -not $Confirm2) {
    throw 'Scenario All breaks everything at once. Re-run with -Confirm2 if that is what you want.'
}

#---------------------------------------------------------------------------
# state file: what we broke, and what it was before
#---------------------------------------------------------------------------
$stateDir = Split-Path -Parent $cfg.StateFile
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Get-LabState {
    if (Test-Path $cfg.StateFile) {
        return Get-Content -Raw -Path $cfg.StateFile | ConvertFrom-Json
    }
    return [pscustomobject]@{ Broken = @() }
}

function Add-LabState {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][hashtable]$Before
    )
    $state = Get-LabState
    $entry = [pscustomobject]@{
        Scenario   = $Scenario
        BrokenAt   = (Get-Date).ToString('o')
        BrokenBy   = "$env:USERDOMAIN\$env:USERNAME"
        Before     = [pscustomobject]$Before
    }
    # Keep only the newest entry per scenario, so repeated breaks do not
    # bury the original pre-break value.
    $kept = @($state.Broken | Where-Object { $_.Scenario -ne $Scenario })
    $state.Broken = @($kept + $entry)
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $cfg.StateFile -Encoding UTF8
    Write-LabInfo "recorded pre-break state in $($cfg.StateFile)"
}

function Invoke-LabSqlCmd {
    param([Parameter(Mandatory)][string]$Query, [string]$Database = 'master')
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module SqlServer -ErrorAction Stop
        return Invoke-Sqlcmd -ServerInstance $cfg.SqlInstance -Database $Database `
                   -Query $Query -TrustServerCertificate -ErrorAction Stop
    }
    $out = & sqlcmd.exe -S $cfg.SqlInstance -d $Database -E -b -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $($out -join ' ')" }
    return $out
}

#===========================================================================
function Invoke-BreakBadServiceAccountPassword {
    Write-LabStep 'Breaking: bad service-account password'

    $isLocal = $cfg.ServiceAccount.StartsWith('.\')
    if (-not $isLocal) {
        Write-LabWarn 'Service account is a domain account; this script will not change an AD password.'
        Write-LabInfo 'To inject this failure on a domain VM, reset the password in AD and do NOT'
        Write-LabInfo 'update the app pool. Then run Invoke-LabHealthCheck.ps1.'
        return
    }

    $poolPath = "IIS:\AppPools\$($cfg.AppPoolName)"
    $pool = Get-Item $poolPath
    $currentUser = $pool.processModel.userName

    Write-LabInfo "app pool identity is $currentUser"
    Write-LabInfo 'Rotating the Windows password and leaving IIS holding the old one.'

    # A random password nobody needs to know: the fix re-sets it.
    # Built from RandomNumberGenerator rather than System.Web, which is
    # .NET Framework only and absent from PowerShell 7.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_=+'
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $newPwd = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    $secure = ConvertTo-SecureString -String $newPwd -AsPlainText -Force

    Add-LabState -Scenario 'BadServiceAccountPassword' -Before @{
        AppPoolIdentity = $currentUser
        Note            = 'Windows password was rotated; IIS still stores the previous one.'
    }

    Set-LocalUser -Name $cfg.ServiceAccountName -Password $secure
    Write-LabOk 'Windows password changed'
    $newPwd = $null

    # Force the pool to try (and fail) to start a worker.
    try { Stop-WebAppPool  -Name $cfg.AppPoolName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    try { Start-WebAppPool -Name $cfg.AppPoolName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2

    foreach ($i in 1..3) {
        try { Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 5 | Out-Null }
        catch { }
        Start-Sleep -Seconds 2
    }

    Write-LabOk 'Injected. Expected symptoms:'
    Write-LabInfo '  - app pool stops on its own, or will not stay started'
    Write-LabInfo '  - HTTP 503 Service Unavailable from the site'
    Write-LabInfo '  - System event log, source WAS, event 5021 ("identity is invalid")'
    Write-LabInfo '  - Security log event 4625 for the service account'
    Write-LabInfo 'Runbook: runbooks/01-bad-service-account-password.md'
}

#===========================================================================
function Invoke-BreakStoppedAppPool {
    Write-LabStep 'Breaking: stopped app pool'

    $state = (Get-WebAppPoolState -Name $cfg.AppPoolName).Value
    $autoStart = (Get-ItemProperty "IIS:\AppPools\$($cfg.AppPoolName)" -Name autoStart).Value

    Add-LabState -Scenario 'StoppedAppPool' -Before @{
        State     = $state
        AutoStart = $autoStart
        Mode      = $(if ($CrashLoop) { 'CrashLoop' } else { 'CleanStop' })
    }

    if ($CrashLoop) {
        Write-LabInfo 'Making the worker fail to start, so rapid-fail protection stops the pool.'
        # Point HttpPlatformHandler at an interpreter that does not exist.
        $webConfig = Join-Path $cfg.SitePath 'web.config'
        [xml]$wc = Get-Content $webConfig
        $wc.configuration.'system.webServer'.httpPlatform.processPath = 'C:\Python312\python-does-not-exist.exe'
        $wc.Save($webConfig)
        Write-LabOk 'web.config now names a missing interpreter'

        Start-WebAppPool -Name $cfg.AppPoolName -ErrorAction SilentlyContinue
        # Each request makes IIS try to start the child process and fail.
        foreach ($i in 1..7) {
            try { Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
            Start-Sleep -Milliseconds 800
        }
        $after = (Get-WebAppPoolState -Name $cfg.AppPoolName).Value
        Write-LabOk "pool state is now: $after"
        Write-LabInfo 'If it is still Started, send a few more requests; rapid-fail needs 5 crashes in 5 minutes.'
    }
    else {
        Stop-WebAppPool -Name $cfg.AppPoolName
        Start-Sleep -Seconds 2
        # Also clear autoStart so a service restart does not quietly fix it.
        Set-ItemProperty "IIS:\AppPools\$($cfg.AppPoolName)" -Name autoStart -Value $false
        Write-LabOk "pool stopped and autoStart set to false"
    }

    Write-LabOk 'Injected. Expected symptoms:'
    Write-LabInfo '  - HTTP 503 Service Unavailable, immediately, with no app log entry'
    Write-LabInfo '  - the site itself still shows as Started in IIS Manager'
    Write-LabInfo '  - Get-WebAppPoolState returns Stopped'
    Write-LabInfo 'Runbook: runbooks/02-stopped-app-pool.md'
}

#===========================================================================
function Invoke-BreakBadConnectionString {
    Write-LabStep 'Breaking: bad connection string'

    $webConfig = Join-Path $cfg.SitePath 'web.config'
    [xml]$wc = Get-Content $webConfig
    $node = $wc.configuration.'system.webServer'.httpPlatform.environmentVariables.environmentVariable |
            Where-Object { $_.name -eq 'ORDERDESK_SQL_SERVER' }

    if (-not $node) { throw "ORDERDESK_SQL_SERVER is not in $webConfig; re-run Deploy-LabApp.ps1." }

    $before = $node.value
    Add-LabState -Scenario 'BadConnectionString' -Before @{
        WebConfig            = $webConfig
        ORDERDESK_SQL_SERVER = $before
    }

    # A plausible typo rather than obvious nonsense: the kind of thing that
    # really happens when a config is hand-edited between environments.
    $node.SetAttribute('value', 'localhost\SQLEXPRES')
    $wc.Save($webConfig)
    Write-LabOk "ORDERDESK_SQL_SERVER: '$before' -> 'localhost\SQLEXPRES'"

    Restart-WebAppPool -Name $cfg.AppPoolName
    Start-Sleep -Seconds 4
    try { Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {}

    Write-LabOk 'Injected. Expected symptoms:'
    Write-LabInfo '  - the site loads, so IIS and the app pool are fine'
    Write-LabInfo '  - /health returns HTTP 503 with kind="unreachable"'
    Write-LabInfo '  - /orders shows "Database unavailable" naming the SQL instance it tried'
    Write-LabInfo '  - no SQL login failure at all: SQL never saw a connection'
    Write-LabInfo 'Runbook: runbooks/03-bad-connection-string.md'
}

#===========================================================================
function Invoke-BreakPermissionDenied {
    Write-LabStep 'Breaking: permission denied'

    $svcAcct = if ($cfg.ServiceAccount.StartsWith('.\')) {
        "$env:COMPUTERNAME\$($cfg.ServiceAccountName)"
    } else { $cfg.ServiceAccount }

    Add-LabState -Scenario 'PermissionDenied' -Before @{
        Principal = 'OrderDeskApp'
        Account   = $svcAcct
        Note      = 'SELECT on app.Orders was granted via the OrderDeskApp role.'
    }

    # DENY beats GRANT, so this reproduces the real failure precisely while
    # leaving the original GRANT in place for the fix to fall back on.
    $q = @"
USE AppSupportLab;
DENY SELECT ON OBJECT::app.Orders TO OrderDeskApp;
SELECT 'denied' AS Result;
"@
    Invoke-LabSqlCmd -Query $q -Database $cfg.Database | Out-Null
    Write-LabOk 'DENY SELECT ON app.Orders TO OrderDeskApp'

    Restart-WebAppPool -Name $cfg.AppPoolName
    Start-Sleep -Seconds 4
    try { Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {}

    Write-LabOk 'Injected. Expected symptoms:'
    Write-LabInfo '  - the site loads and SQL is reachable'
    Write-LabInfo '  - /health returns 503 with kind="permission_denied", SQL error 229'
    Write-LabInfo '  - "The SELECT permission was denied on the object ''Orders''"'
    Write-LabInfo '  - the login itself succeeds; only the statement is refused'
    Write-LabInfo 'Runbook: runbooks/04-permission-denied.md'
}

#===========================================================================
Write-LabStep "Lab break: $Scenario"
Write-LabWarn 'This degrades the lab service on purpose.'

switch ($Scenario) {
    'BadServiceAccountPassword' { Invoke-BreakBadServiceAccountPassword }
    'StoppedAppPool'            { Invoke-BreakStoppedAppPool }
    'BadConnectionString'       { Invoke-BreakBadConnectionString }
    'PermissionDenied'          { Invoke-BreakPermissionDenied }
    'All' {
        Invoke-BreakBadServiceAccountPassword
        Invoke-BreakStoppedAppPool
        Invoke-BreakBadConnectionString
        Invoke-BreakPermissionDenied
    }
}

Write-LabStep 'Next'
Write-LabInfo 'Diagnose it yourself first:   .\Invoke-LabHealthCheck.ps1'
Write-LabInfo 'Then read the matching runbook and fix it by hand.'
Write-LabInfo "Shortcut if you are out of time: .\Invoke-LabFix.ps1 -Scenario $Scenario"
