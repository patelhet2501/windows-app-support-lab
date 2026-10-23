<#
.SYNOPSIS
    Repairs the failures injected by Invoke-LabBreak.ps1.

.DESCRIPTION
    Use it as a backstop, not a first resort: the point of the lab is to
    diagnose and fix by hand with the runbooks. Each function here does
    exactly what its runbook's "Fix" section describes, in the same order,
    and verifies afterwards.

    The state file written by Invoke-LabBreak.ps1 supplies the pre-break
    values. Where a value cannot be recovered (a rotated password), the
    script prompts.

.PARAMETER Scenario
    Which failure to repair, or All to repair everything that is recorded
    as broken.

.PARAMETER ServiceAccountCredential
    New password for the service account, for the BadServiceAccountPassword
    fix. Prompted for when omitted.

.EXAMPLE
    .\Invoke-LabFix.ps1 -Scenario StoppedAppPool
.EXAMPLE
    .\Invoke-LabFix.ps1 -Scenario All
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('BadServiceAccountPassword', 'StoppedAppPool',
                 'BadConnectionString', 'PermissionDenied', 'All')]
    [string]$Scenario,

    [System.Management.Automation.PSCredential]$ServiceAccountCredential
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.config.ps1"
Assert-LabAdmin
$cfg = Get-LabConfig
Import-Module WebAdministration -ErrorAction Stop

function Get-LabState {
    if (Test-Path $cfg.StateFile) {
        return Get-Content -Raw -Path $cfg.StateFile | ConvertFrom-Json
    }
    return [pscustomobject]@{ Broken = @() }
}

function Get-LabBreakEntry {
    param([Parameter(Mandatory)][string]$Scenario)
    $state = Get-LabState
    return $state.Broken | Where-Object { $_.Scenario -eq $Scenario } |
           Sort-Object BrokenAt -Descending | Select-Object -First 1
}

function Clear-LabBreakEntry {
    param([Parameter(Mandatory)][string]$Scenario)
    $state = Get-LabState
    $state.Broken = @($state.Broken | Where-Object { $_.Scenario -ne $Scenario })
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $cfg.StateFile -Encoding UTF8
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

function Test-LabHealthy {
    <#  True when /health answers 200. Used to verify each fix. #>
    param([int]$Attempts = 8, [int]$DelaySeconds = 3)
    foreach ($i in 1..$Attempts) {
        try {
            $r = Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 10
            if ($r.StatusCode -eq 200) {
                $b = $r.Content | ConvertFrom-Json
                Write-LabOk "/health 200 status=$($b.status) identity=$($b.identity)"
                return $true
            }
        }
        catch {
            $code = $null
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            Write-LabInfo "attempt ${i}/${Attempts}: $(if ($code) { "HTTP $code" } else { $_.Exception.Message })"
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

#===========================================================================
function Invoke-FixBadServiceAccountPassword {
    Write-LabStep 'Fixing: bad service-account password'

    $isLocal = $cfg.ServiceAccount.StartsWith('.\')
    $qualified = if ($isLocal) { "$env:COMPUTERNAME\$($cfg.ServiceAccountName)" } else { $cfg.ServiceAccount }

    if (-not $ServiceAccountCredential) {
        Write-LabInfo 'Set a new password for the service account. It will be applied in BOTH'
        Write-LabInfo 'places that must agree: Windows and the IIS app pool.'
        $ServiceAccountCredential = Get-Credential -UserName $qualified -Message 'New service account password'
    }

    # 1. Windows side.
    if ($isLocal) {
        Set-LocalUser -Name $cfg.ServiceAccountName -Password $ServiceAccountCredential.Password
        Write-LabOk 'Windows password set'

        $lu = Get-LocalUser -Name $cfg.ServiceAccountName
        if (-not $lu.Enabled) {
            Enable-LocalUser -Name $cfg.ServiceAccountName
            Write-LabOk 'account re-enabled'
        }
    }
    else {
        Write-LabWarn 'Domain account: reset the password in AD yourself, then re-run this.'
        Write-LabInfo 'This script will still update the app pool with the password you just entered.'
    }

    # 2. IIS side - the step that is forgotten in the real world.
    Set-ItemProperty -Path "IIS:\AppPools\$($cfg.AppPoolName)" -Name processModel -Value @{
        identityType = 3
        userName     = $ServiceAccountCredential.UserName
        password     = $ServiceAccountCredential.GetNetworkCredential().Password
    }
    Write-LabOk 'app pool identity updated with the same password'

    # 3. Clear the rapid-fail stop and start the pool.
    Set-ItemProperty -Path "IIS:\AppPools\$($cfg.AppPoolName)" -Name autoStart -Value $true
    if ((Get-WebAppPoolState -Name $cfg.AppPoolName).Value -ne 'Started') {
        Start-WebAppPool -Name $cfg.AppPoolName
    }
    else {
        Restart-WebAppPool -Name $cfg.AppPoolName
    }
    Write-LabOk 'app pool started'

    if (Test-LabHealthy) {
        Clear-LabBreakEntry -Scenario 'BadServiceAccountPassword'
        Write-LabOk 'Fixed and verified.'
    }
    else {
        Write-LabFail 'Still unhealthy. Check WAS event 5021 and that the two passwords really match.'
    }
}

#===========================================================================
function Invoke-FixStoppedAppPool {
    Write-LabStep 'Fixing: stopped app pool'

    $entry = Get-LabBreakEntry -Scenario 'StoppedAppPool'
    $mode = if ($entry) { $entry.Before.Mode } else { 'Unknown' }
    Write-LabInfo "recorded break mode: $mode"

    # If the crash-loop variant was used, web.config names a missing
    # interpreter. Repair that before starting the pool, or it just stops again.
    $webConfig = Join-Path $cfg.SitePath 'web.config'
    [xml]$wc = Get-Content $webConfig
    $pp = $wc.configuration.'system.webServer'.httpPlatform.processPath
    if (-not (Test-Path $pp)) {
        Write-LabWarn "processPath '$pp' does not exist"
        if (-not (Test-Path $cfg.PythonExe)) {
            throw "Cannot repair: $($cfg.PythonExe) is also missing. Re-run Install-LabPrereqs.ps1."
        }
        $wc.configuration.'system.webServer'.httpPlatform.processPath = $cfg.PythonExe
        $wc.Save($webConfig)
        Write-LabOk "processPath set back to $($cfg.PythonExe)"
    }
    else {
        Write-LabOk "processPath '$pp' is valid"
    }

    # autoStart false is why it stayed down across a restart.
    $autoStart = (Get-ItemProperty "IIS:\AppPools\$($cfg.AppPoolName)" -Name autoStart).Value
    if (-not $autoStart) {
        Set-ItemProperty "IIS:\AppPools\$($cfg.AppPoolName)" -Name autoStart -Value $true
        Write-LabOk 'autoStart re-enabled'
    }

    if ((Get-Service W3SVC).Status -ne 'Running') {
        Start-Service W3SVC
        Write-LabOk 'W3SVC started'
    }

    $state = (Get-WebAppPoolState -Name $cfg.AppPoolName).Value
    if ($state -ne 'Started') {
        Start-WebAppPool -Name $cfg.AppPoolName
        Write-LabOk "app pool started (was $state)"
    }
    else {
        Restart-WebAppPool -Name $cfg.AppPoolName
        Write-LabOk 'app pool recycled'
    }

    if (Test-LabHealthy) {
        Clear-LabBreakEntry -Scenario 'StoppedAppPool'
        Write-LabOk 'Fixed and verified.'
    }
    else {
        Write-LabFail 'Still unhealthy. Another failure may also be injected; run Invoke-LabHealthCheck.ps1.'
    }
}

#===========================================================================
function Invoke-FixBadConnectionString {
    Write-LabStep 'Fixing: bad connection string'

    $entry = Get-LabBreakEntry -Scenario 'BadConnectionString'
    $restore = if ($entry -and $entry.Before.ORDERDESK_SQL_SERVER) {
        $entry.Before.ORDERDESK_SQL_SERVER
    } else {
        Write-LabInfo 'no recorded pre-break value; falling back to lab.config.ps1'
        $cfg.SqlInstance
    }

    $webConfig = Join-Path $cfg.SitePath 'web.config'
    [xml]$wc = Get-Content $webConfig
    $node = $wc.configuration.'system.webServer'.httpPlatform.environmentVariables.environmentVariable |
            Where-Object { $_.name -eq 'ORDERDESK_SQL_SERVER' }
    if (-not $node) { throw "ORDERDESK_SQL_SERVER is missing from $webConfig; re-run Deploy-LabApp.ps1." }

    $bad = $node.value

    # Prove the target is actually reachable BEFORE putting it in the config.
    try {
        Invoke-LabSqlCmd -Query 'SELECT 1 AS Ok' | Out-Null
        Write-LabOk "verified $($cfg.SqlInstance) answers before changing the config"
    }
    catch {
        throw "Cannot reach $($cfg.SqlInstance) either ($($_.Exception.Message)). Fix SQL first."
    }

    $node.SetAttribute('value', $restore)
    $wc.Save($webConfig)
    Write-LabOk "ORDERDESK_SQL_SERVER: '$bad' -> '$restore'"

    Restart-WebAppPool -Name $cfg.AppPoolName
    Write-LabOk 'app pool recycled to pick up the new environment variable'

    if (Test-LabHealthy) {
        Clear-LabBreakEntry -Scenario 'BadConnectionString'
        Write-LabOk 'Fixed and verified.'
    }
    else {
        Write-LabFail 'Still unhealthy. Compare /diag against the SQL instance name.'
    }
}

#===========================================================================
function Invoke-FixPermissionDenied {
    Write-LabStep 'Fixing: permission denied'

    # REVOKE removes the DENY; the original GRANT from sql\06 then applies
    # again. Re-granting explicitly makes the script safe to run even if the
    # original grant was lost too.
    $q = @"
USE AppSupportLab;

REVOKE SELECT ON OBJECT::app.Orders FROM OrderDeskApp;
GRANT  SELECT, INSERT, UPDATE ON SCHEMA::app TO OrderDeskApp;

SELECT  p.permission_name, p.state_desc, OBJECT_NAME(p.major_id) AS ObjectName
FROM    sys.database_permissions p
JOIN    sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
WHERE   dp.name = 'OrderDeskApp'
ORDER BY p.state_desc DESC, p.permission_name;
"@
    $rows = Invoke-LabSqlCmd -Query $q -Database $cfg.Database
    Write-LabOk 'DENY removed and schema grants reapplied'
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    # Confirm as the app's own principal, not as sysadmin.
    $svcAcct = if ($cfg.ServiceAccount.StartsWith('.\')) {
        "$env:COMPUTERNAME\$($cfg.ServiceAccountName)"
    } else { $cfg.ServiceAccount }

    $verify = @"
USE AppSupportLab;
BEGIN TRY
    EXECUTE AS LOGIN = '$svcAcct';
    DECLARE @n int; SELECT @n = COUNT(*) FROM app.Orders;
    REVERT;
    SELECT 'OK' AS Result, @n AS Orders;
END TRY
BEGIN CATCH
    BEGIN TRY REVERT; END TRY BEGIN CATCH END CATCH
    SELECT 'FAILED' AS Result, ERROR_NUMBER() AS Orders;
END CATCH
"@
    $v = Invoke-LabSqlCmd -Query $verify -Database $cfg.Database
    Write-LabInfo "impersonated read: $($v | Out-String)".Trim()

    Restart-WebAppPool -Name $cfg.AppPoolName

    if (Test-LabHealthy) {
        Clear-LabBreakEntry -Scenario 'PermissionDenied'
        Write-LabOk 'Fixed and verified.'
    }
    else {
        Write-LabFail 'Still unhealthy. Check for a DENY at schema or database-role level too.'
    }
}

#===========================================================================
Write-LabStep "Lab fix: $Scenario"

switch ($Scenario) {
    'BadServiceAccountPassword' { Invoke-FixBadServiceAccountPassword }
    'StoppedAppPool'            { Invoke-FixStoppedAppPool }
    'BadConnectionString'       { Invoke-FixBadConnectionString }
    'PermissionDenied'          { Invoke-FixPermissionDenied }
    'All' {
        # Order matters: repair the config and permissions first, so the
        # pool has something healthy to start against.
        Invoke-FixBadConnectionString
        Invoke-FixPermissionDenied
        Invoke-FixBadServiceAccountPassword
        Invoke-FixStoppedAppPool
    }
}

Write-LabStep 'Verifying the whole lab'
& "$PSScriptRoot\Invoke-LabHealthCheck.ps1"
$code = $LASTEXITCODE

if ($code -eq 0) { Write-LabOk 'Health check reports no failures.' }
else { Write-LabWarn "Health check still reports $code failure(s)." }

exit $code
