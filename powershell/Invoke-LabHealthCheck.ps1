<#
.SYNOPSIS
    Health check for the OrderDesk lab: Windows services, IIS app pools and
    site, the app's own /health endpoint, SQL connectivity and permissions,
    SQL Agent jobs (or their Scheduled Task stand-ins), and recent event-log
    and job failures.

.DESCRIPTION
    Read-only. Changes nothing, so it is safe to run at any point during an
    incident - including before you know what is wrong.

    Every check emits an object with:
      Area        grouping (Service, AppPool, Site, App, Sql, Jobs, System)
      Check       what was tested
      Status      Pass | Warn | Fail | Skip
      Detail      what was actually observed
      Remediation the next action, and the runbook when one applies

    Exit code is the number of Fail results, so it works as a monitor probe:
        powershell -File Invoke-LabHealthCheck.ps1 -Quiet; if ($LASTEXITCODE) {...}

.PARAMETER Json
    Emit JSON instead of a table. For piping into a monitoring system.

.PARAMETER Quiet
    Print nothing; just set the exit code.

.PARAMETER IncludeEventLog
    Scan the System and Application logs for the errors these failures raise
    (WAS 5021/5057/5059, and app-pool crashes). On by default; -IncludeEventLog:$false
    skips it on a slow VM.

.PARAMETER EventLogHours
    How far back to scan. Default 24.

.EXAMPLE
    .\Invoke-LabHealthCheck.ps1
.EXAMPLE
    .\Invoke-LabHealthCheck.ps1 -Json | Out-File C:\LabState\health.json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Quiet,
    [bool]$IncludeEventLog = $true,
    [int]$EventLogHours = 24
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lab.config.ps1"
$cfg = Get-LabConfig

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'Skip')][string]$Status,
        [string]$Detail = '',
        [string]$Remediation = ''
    )
    $results.Add([pscustomobject]@{
        Area        = $Area
        Check       = $Check
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
    })
}

function Test-LabAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-LabAdmin
if (-not $isAdmin -and -not $Quiet) {
    Write-LabWarn 'Not elevated: IIS configuration and event-log checks will be skipped.'
}

#===========================================================================
# 1. Windows services
#===========================================================================
foreach ($name in $cfg.WatchedServices) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Result -Area 'Service' -Check $name -Status 'Fail' `
            -Detail 'service is not installed' `
            -Remediation 'Run Install-LabPrereqs.ps1; check lab.config.ps1 names the right instance.'
        continue
    }

    $startType = try { (Get-Service -Name $name).StartType } catch { 'Unknown' }

    if ($svc.Status -eq 'Running') {
        Add-Result -Area 'Service' -Check $name -Status 'Pass' `
            -Detail "Running (startup: $startType)"
    }
    else {
        $rem = switch ($name) {
            'W3SVC'  { 'Start-Service W3SVC. If it will not start, see runbooks/02-stopped-app-pool.md.' }
            'WAS'    { 'Start-Service WAS first; W3SVC depends on it.' }
            default  { "Start-Service '$name'. If SQL will not start, check its ErrorLog under the instance MSSQL\LOG." }
        }
        if ($startType -eq 'Disabled') {
            $rem = "Service is disabled: Set-Service '$name' -StartupType Automatic, then Start-Service. $rem"
        }
        Add-Result -Area 'Service' -Check $name -Status 'Fail' `
            -Detail "$($svc.Status) (startup: $startType)" -Remediation $rem
    }
}

# SQL Agent is a special case: absent on Express by design, not a fault.
$agent = Get-Service -Name $cfg.SqlAgentServiceName -ErrorAction SilentlyContinue
$sqlEdition = $null
if (-not $agent) {
    Add-Result -Area 'Service' -Check $cfg.SqlAgentServiceName -Status 'Skip' `
        -Detail 'SQL Agent service is not installed' `
        -Remediation 'Expected on SQL Express. Use Developer edition for the SQL Agent part of the lab.'
}
elseif ($agent.Status -eq 'Running') {
    Add-Result -Area 'Service' -Check $cfg.SqlAgentServiceName -Status 'Pass' -Detail 'Running'
}
else {
    Add-Result -Area 'Service' -Check $cfg.SqlAgentServiceName -Status 'Warn' `
        -Detail "$($agent.Status) (startup: $($agent.StartType))" `
        -Remediation 'On Express this cannot start and is expected. On Developer/Standard: Start-Service.'
}

#===========================================================================
# 2. IIS app pool and site
#===========================================================================
$iisOk = $false
if ($isAdmin) {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $iisOk = $true
    }
    catch {
        Add-Result -Area 'AppPool' -Check 'WebAdministration module' -Status 'Fail' `
            -Detail $_.Exception.Message `
            -Remediation 'Install-WindowsFeature Web-Scripting-Tools'
    }
}
else {
    Add-Result -Area 'AppPool' -Check 'IIS configuration' -Status 'Skip' `
        -Detail 'needs an elevated session' -Remediation 'Re-run as Administrator.'
}

if ($iisOk) {
    $poolPath = "IIS:\AppPools\$($cfg.AppPoolName)"

    if (-not (Test-Path $poolPath)) {
        Add-Result -Area 'AppPool' -Check $cfg.AppPoolName -Status 'Fail' `
            -Detail 'app pool does not exist' -Remediation 'Run Deploy-LabApp.ps1.'
    }
    else {
        $state = (Get-WebAppPoolState -Name $cfg.AppPoolName).Value
        if ($state -eq 'Started') {
            Add-Result -Area 'AppPool' -Check "$($cfg.AppPoolName) state" -Status 'Pass' -Detail 'Started'
        }
        else {
            Add-Result -Area 'AppPool' -Check "$($cfg.AppPoolName) state" -Status 'Fail' `
                -Detail $state `
                -Remediation "Start-WebAppPool '$($cfg.AppPoolName)'. If it stops again, see runbooks/02-stopped-app-pool.md."
        }

        $pool = Get-Item $poolPath
        $idType = $pool.processModel.identityType
        $idUser = $pool.processModel.userName
        $idDesc = switch ("$idType") {
            'ApplicationPoolIdentity' { 'ApplicationPoolIdentity (virtual account)' }
            'SpecificUser'            { "SpecificUser: $idUser" }
            'NetworkService'          { 'NetworkService' }
            'LocalSystem'             { 'LocalSystem' }
            'LocalService'            { 'LocalService' }
            default                   { "$idType $idUser" }
        }

        if ("$idType" -eq 'SpecificUser' -and $idUser) {
            Add-Result -Area 'AppPool' -Check 'identity' -Status 'Pass' -Detail $idDesc
        }
        elseif ("$idType" -eq 'SpecificUser') {
            Add-Result -Area 'AppPool' -Check 'identity' -Status 'Fail' `
                -Detail 'SpecificUser with an empty user name' `
                -Remediation 'Re-run Deploy-LabApp.ps1 to set the identity.'
        }
        else {
            Add-Result -Area 'AppPool' -Check 'identity' -Status 'Warn' `
                -Detail $idDesc `
                -Remediation "Lab expects a specific service account ($($cfg.ServiceAccount)); SQL access is Integrated Security."
        }

        # Rapid-fail protection having TRIPPED is the signal worth surfacing:
        # the pool is stopped, autoStart is still true, and WAS logged 5002.
        $rfp = $pool.failure.rapidFailProtection
        Add-Result -Area 'AppPool' -Check 'rapid-fail protection' `
            -Status $(if ($rfp) { 'Pass' } else { 'Warn' }) `
            -Detail "enabled=$rfp maxCrashes=$($pool.failure.rapidFailProtectionMaxCrashes) interval=$($pool.failure.rapidFailProtectionInterval)" `
            -Remediation $(if ($rfp) { '' } else { 'Lab expects it on, so crash loops stop the pool visibly.' })

        # A worker process present means the pool is not merely "Started" on paper.
        $workers = @()
        try { $workers = @(Get-ChildItem "IIS:\AppPools\$($cfg.AppPoolName)\WorkerProcesses" -ErrorAction Stop) } catch {}
        if ($workers.Count -gt 0) {
            $pids = ($workers | ForEach-Object { $_.processId }) -join ', '
            Add-Result -Area 'AppPool' -Check 'worker process' -Status 'Pass' `
                -Detail "$($workers.Count) w3wp (PID $pids)"
        }
        elseif ($state -eq 'Started') {
            Add-Result -Area 'AppPool' -Check 'worker process' -Status 'Warn' `
                -Detail 'pool is Started but no w3wp is running' `
                -Remediation 'Normal before the first request. Hit the site, then re-check.'
        }
    }

    # --- site ---
    $site = Get-Website -Name $cfg.SiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        Add-Result -Area 'Site' -Check $cfg.SiteName -Status 'Fail' `
            -Detail 'website does not exist' -Remediation 'Run Deploy-LabApp.ps1.'
    }
    else {
        Add-Result -Area 'Site' -Check "$($cfg.SiteName) state" `
            -Status $(if ($site.State -eq 'Started') { 'Pass' } else { 'Fail' }) `
            -Detail $site.State `
            -Remediation $(if ($site.State -eq 'Started') { '' } else { "Start-Website '$($cfg.SiteName)'" })

        $bindings = ($site.bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ', '
        Add-Result -Area 'Site' -Check 'bindings' -Status 'Pass' -Detail $bindings

        if (Test-Path $site.physicalPath) {
            Add-Result -Area 'Site' -Check 'physical path' -Status 'Pass' -Detail $site.physicalPath
        }
        else {
            Add-Result -Area 'Site' -Check 'physical path' -Status 'Fail' `
                -Detail "$($site.physicalPath) does not exist" -Remediation 'Run Deploy-LabApp.ps1.'
        }

        if ($site.applicationPool -ne $cfg.AppPoolName) {
            Add-Result -Area 'Site' -Check 'app pool assignment' -Status 'Warn' `
                -Detail "site uses '$($site.applicationPool)'" `
                -Remediation "Lab expects '$($cfg.AppPoolName)'."
        }
    }

    # --- HttpPlatformHandler, without which the site returns 500.21 ---
    $hph = Get-WebGlobalModule -ErrorAction SilentlyContinue |
           Where-Object Name -eq 'httpPlatformHandler'
    Add-Result -Area 'Site' -Check 'HttpPlatformHandler module' `
        -Status $(if ($hph) { 'Pass' } else { 'Fail' }) `
        -Detail $(if ($hph) { 'registered' } else { 'not registered' }) `
        -Remediation $(if ($hph) { '' } else { 'Install it: Install-LabPrereqs.ps1. Without it IIS returns HTTP 500.21.' })
}

#===========================================================================
# 3. the app's own health endpoint
#===========================================================================
$appIdentity = $null
try {
    $resp = Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 15
    $body = $resp.Content | ConvertFrom-Json
    $appIdentity = $body.identity
    Add-Result -Area 'App' -Check 'GET /health' -Status 'Pass' `
        -Detail "HTTP $($resp.StatusCode) status=$($body.status) identity=$($body.identity) db=$($body.checks.database.latency_ms)ms"
}
catch {
    $ex = $_
    $resp = $ex.Exception.Response
    if ($resp) {
        $code = $resp.StatusCode.value__
        $raw = ''
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $raw = $sr.ReadToEnd()
            $sr.Close()
        } catch {}

        if ($code -eq 503) {
            # The app is alive and telling us which dependency failed.
            $kind = 'unknown'; $msg = $raw
            try { $j = $raw | ConvertFrom-Json; $kind = $j.kind; $msg = $j.message } catch {}
            $rb = switch ($kind) {
                'login_failed'      { 'runbooks/01-bad-service-account-password.md' }
                'permission_denied' { 'runbooks/04-permission-denied.md' }
                'unreachable'       { 'runbooks/03-bad-connection-string.md' }
                'missing_object'    { 'runbooks/03-bad-connection-string.md' }
                default             { 'runbooks/00-index.md' }
            }
            Add-Result -Area 'App' -Check 'GET /health' -Status 'Fail' `
                -Detail "HTTP 503 degraded - kind=$kind: $msg" -Remediation "See $rb"
        }
        elseif ($code -eq 502 -or $code -eq 500) {
            Add-Result -Area 'App' -Check 'GET /health' -Status 'Fail' `
                -Detail "HTTP $code from IIS" `
                -Remediation 'App pool is stopped or the worker will not start: runbooks/02-stopped-app-pool.md'
        }
        else {
            Add-Result -Area 'App' -Check 'GET /health' -Status 'Fail' `
                -Detail "HTTP $code" `
                -Remediation 'Check the app pool and HttpPlatformHandler stdout log.'
        }
    }
    else {
        Add-Result -Area 'App' -Check 'GET /health' -Status 'Fail' `
            -Detail $ex.Exception.Message `
            -Remediation "Nothing is listening on $($cfg.SitePort). Check W3SVC and the app pool: runbooks/02-stopped-app-pool.md"
    }
}

# Is the port even listening? Distinguishes "IIS down" from "app broken".
$listening = Get-NetTCPConnection -LocalPort $cfg.SitePort -State Listen -ErrorAction SilentlyContinue
Add-Result -Area 'App' -Check "TCP $($cfg.SitePort) listening" `
    -Status $(if ($listening) { 'Pass' } else { 'Fail' }) `
    -Detail $(if ($listening) { "owned by PID $(($listening | Select-Object -First 1).OwningProcess)" } else { 'nothing is listening' }) `
    -Remediation $(if ($listening) { '' } else { 'W3SVC is not serving the binding. Start-Service W3SVC; Start-Website.' })

# The stdout log is where a Python traceback lands under IIS.
$stdout = Get-ChildItem -Path $cfg.LogPath -Filter 'httpplatform-stdout*.log' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($stdout) {
    $tracebacks = @(Select-String -Path $stdout.FullName -Pattern 'Traceback|Error|Exception' -ErrorAction SilentlyContinue)
    Add-Result -Area 'App' -Check 'stdout log' `
        -Status $(if ($tracebacks.Count -gt 0) { 'Warn' } else { 'Pass' }) `
        -Detail "$($stdout.Name) ($([math]::Round($stdout.Length/1KB,1)) KB), $($tracebacks.Count) error line(s), last write $($stdout.LastWriteTime)" `
        -Remediation $(if ($tracebacks.Count -gt 0) { "Read the tail: Get-Content '$($stdout.FullName)' -Tail 50" } else { '' })
}
else {
    Add-Result -Area 'App' -Check 'stdout log' -Status 'Warn' `
        -Detail "no httpplatform-stdout*.log in $($cfg.LogPath)" `
        -Remediation 'stdoutLogEnabled may be false, or the app-pool identity cannot write there (failure 4).'
}

#===========================================================================
# 4. SQL Server: reachable, the database is there, and the app can read it
#===========================================================================
function Invoke-LabSql {
    <#  Query helper that works with or without the SqlServer module.
        Returns @{ Ok = bool; Rows = object[]; Error = string } #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$TimeoutSec = 10
    )
    if (Get-Module -ListAvailable -Name SqlServer) {
        try {
            Import-Module SqlServer -ErrorAction Stop
            $rows = Invoke-Sqlcmd -ServerInstance $cfg.SqlInstance -Database $Database `
                        -Query $Query -TrustServerCertificate `
                        -ConnectionTimeout $TimeoutSec -QueryTimeout $TimeoutSec -ErrorAction Stop
            return @{ Ok = $true; Rows = @($rows); Error = $null }
        }
        catch { return @{ Ok = $false; Rows = @(); Error = $_.Exception.Message } }
    }

    $out = & sqlcmd.exe -S $cfg.SqlInstance -d $Database -E -b -h -1 -W -s '|' `
                        -l $TimeoutSec -Q $Query 2>&1
    if ($LASTEXITCODE -eq 0) { return @{ Ok = $true; Rows = @($out); Error = $null } }
    return @{ Ok = $false; Rows = @(); Error = ($out -join ' ') }
}

$sqlUp = Invoke-LabSql -Query @"
SELECT CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS Edition,
       CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS Version,
       SUSER_SNAME() AS LoginName
"@

if ($sqlUp.Ok) {
    $row = $sqlUp.Rows | Select-Object -First 1
    $detail = if ($row -is [string]) { $row } else { "$($row.Edition) $($row.Version) as $($row.LoginName)" }
    $sqlEdition = if ($row -is [string]) { $row } else { $row.Edition }
    Add-Result -Area 'Sql' -Check 'connect to instance' -Status 'Pass' -Detail $detail
}
else {
    Add-Result -Area 'Sql' -Check 'connect to instance' -Status 'Fail' `
        -Detail $sqlUp.Error `
        -Remediation "Check the $($cfg.SqlServiceName) service and that the instance name in lab.config.ps1 is right: runbooks/03-bad-connection-string.md"
}

if ($sqlUp.Ok) {
    $dbCheck = Invoke-LabSql -Query "SELECT name, state_desc, user_access_desc FROM sys.databases WHERE name = '$($cfg.Database)'"
    if ($dbCheck.Ok -and $dbCheck.Rows.Count -gt 0) {
        $r = $dbCheck.Rows | Select-Object -First 1
        $d = if ($r -is [string]) { $r } else { "$($r.name): $($r.state_desc), $($r.user_access_desc)" }
        $online = "$d" -match 'ONLINE'
        Add-Result -Area 'Sql' -Check 'database present' `
            -Status $(if ($online) { 'Pass' } else { 'Fail' }) -Detail $d `
            -Remediation $(if ($online) { '' } else { 'Database is not ONLINE. Check the SQL ErrorLog.' })
    }
    else {
        Add-Result -Area 'Sql' -Check 'database present' -Status 'Fail' `
            -Detail "$($cfg.Database) not found on $($cfg.SqlInstance)" `
            -Remediation 'Run sql\01_schema.sql, or fix the database name: runbooks/03-bad-connection-string.md'
    }

    # Objects the app needs.
    $objCheck = Invoke-LabSql -Database $cfg.Database -Query @"
SELECT COUNT(*) AS Present FROM sys.objects
WHERE object_id IN (OBJECT_ID('app.Orders'), OBJECT_ID('app.OrderLines'),
                    OBJECT_ID('app.Customers'), OBJECT_ID('audit.OrderAudit'),
                    OBJECT_ID('app.vw_OrderVariance'))
"@
    if ($objCheck.Ok) {
        $n = ($objCheck.Rows | Select-Object -First 1)
        $count = if ($n -is [string]) { ($n -replace '\D', '') } else { $n.Present }
        Add-Result -Area 'Sql' -Check 'app objects' `
            -Status $(if ([int]$count -ge 5) { 'Pass' } else { 'Fail' }) `
            -Detail "$count of 5 expected objects present" `
            -Remediation $(if ([int]$count -ge 5) { '' } else { 'Run sql\01_schema.sql.' })
    }

    # The audit trigger must be enabled or changes go unrecorded.
    $trg = Invoke-LabSql -Database $cfg.Database -Query @"
SELECT name, CONVERT(int, is_disabled) AS IsDisabled FROM sys.triggers
WHERE object_id = OBJECT_ID('app.trg_Orders_Audit')
"@
    if ($trg.Ok -and $trg.Rows.Count -gt 0) {
        $t = $trg.Rows | Select-Object -First 1
        $disabled = if ($t -is [string]) { $t -match '\|\s*1\s*$' } else { [int]$t.IsDisabled -eq 1 }
        Add-Result -Area 'Sql' -Check 'audit trigger enabled' `
            -Status $(if ($disabled) { 'Fail' } else { 'Pass' }) `
            -Detail $(if ($disabled) { 'app.trg_Orders_Audit is DISABLED - changes are not being audited' } else { 'app.trg_Orders_Audit is enabled' }) `
            -Remediation $(if ($disabled) { 'ENABLE TRIGGER app.trg_Orders_Audit ON app.Orders;' } else { '' })
    }
    else {
        Add-Result -Area 'Sql' -Check 'audit trigger enabled' -Status 'Fail' `
            -Detail 'app.trg_Orders_Audit does not exist' -Remediation 'Run sql\01_schema.sql.'
    }

    # Does the app's own login still work, and can it read what it needs?
    $svcAcct = if ($cfg.ServiceAccount.StartsWith('.\')) {
        "$env:COMPUTERNAME\$($cfg.ServiceAccountName)"
    } else { $cfg.ServiceAccount }

    $loginCheck = Invoke-LabSql -Query @"
SELECT sp.name, sp.type_desc, CONVERT(int, sp.is_disabled) AS IsDisabled
FROM sys.server_principals sp WHERE sp.name = '$svcAcct'
"@
    if ($loginCheck.Ok -and $loginCheck.Rows.Count -gt 0) {
        $l = $loginCheck.Rows | Select-Object -First 1
        $d = if ($l -is [string]) { $l } else { "$($l.name) ($($l.type_desc)), disabled=$($l.IsDisabled)" }
        $isDisabled = "$d" -match 'disabled=1|\|\s*1\s*$'
        Add-Result -Area 'Sql' -Check 'app login exists' `
            -Status $(if ($isDisabled) { 'Fail' } else { 'Pass' }) -Detail $d `
            -Remediation $(if ($isDisabled) { "ALTER LOGIN [$svcAcct] ENABLE;" } else { '' })
    }
    else {
        Add-Result -Area 'Sql' -Check 'app login exists' -Status 'Fail' `
            -Detail "no SQL login for $svcAcct" `
            -Remediation 'Run sql\06_app_login_permissions.sql: runbooks/04-permission-denied.md'
    }

    # Impersonate the app's principal and try its real query. This is the
    # check that catches failure 4 even while everything else looks healthy.
    $permCheck = Invoke-LabSql -Database $cfg.Database -Query @"
BEGIN TRY
    EXECUTE AS LOGIN = '$svcAcct';
    DECLARE @n int;
    SELECT @n = COUNT(*) FROM app.Orders;
    SELECT 'OK' AS Result, @n AS Orders, 0 AS ErrorNumber, '' AS ErrorMessage;
    REVERT;
END TRY
BEGIN CATCH
    -- REVERT may itself fail if the EXECUTE AS never took effect; ignore that.
    BEGIN TRY REVERT; END TRY BEGIN CATCH END CATCH
    SELECT 'FAILED' AS Result, -1 AS Orders, ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
"@
    if ($permCheck.Ok) {
        $p = $permCheck.Rows | Select-Object -First 1
        $text = if ($p -is [string]) { $p } else { "$($p.Result) orders=$($p.Orders) err=$($p.ErrorNumber) $($p.ErrorMessage)" }
        if ("$text" -match 'OK') {
            Add-Result -Area 'Sql' -Check 'app can read app.Orders' -Status 'Pass' -Detail $text
        }
        else {
            Add-Result -Area 'Sql' -Check 'app can read app.Orders' -Status 'Fail' -Detail $text `
                -Remediation 'The app login lacks SELECT. See runbooks/04-permission-denied.md'
        }
    }
    else {
        Add-Result -Area 'Sql' -Check 'app can read app.Orders' -Status 'Warn' `
            -Detail $permCheck.Error `
            -Remediation 'Could not impersonate; needs IMPERSONATE or sysadmin. Run this check as a sysadmin.'
    }

    # Data health, which is the whole point of the lab.
    $var = Invoke-LabSql -Database $cfg.Database -Query @"
SELECT COUNT(*) AS OutOfBalance,
       ISNULL(SUM(ABS(Variance)), 0) AS AbsVariance
FROM app.vw_OrderVariance WHERE Variance <> 0
"@
    if ($var.Ok) {
        $v = $var.Rows | Select-Object -First 1
        if ($v -is [string]) {
            Add-Result -Area 'Sql' -Check 'order totals reconcile' -Status 'Warn' -Detail "$v"
        }
        else {
            $n = [int]$v.OutOfBalance
            Add-Result -Area 'Sql' -Check 'order totals reconcile' `
                -Status $(if ($n -eq 0) { 'Pass' } else { 'Warn' }) `
                -Detail "$n order(s) out of balance, absolute variance $($v.AbsVariance)" `
                -Remediation $(if ($n -eq 0) { '' } else { 'Investigate with sql\03_investigate.sql, then sql\04_datafix_controlled.sql.' })
        }
    }

    # Did the reconciliation actually run recently?
    $recon = Invoke-LabSql -Database $cfg.Database -Query @"
SELECT TOP 1 RunId, Outcome,
       DATEDIFF(hour, RunStartUtc, SYSUTCDATETIME()) AS HoursAgo,
       ISNULL(Message, '') AS Message
FROM ops.ReconciliationLog ORDER BY RunId DESC
"@
    if ($recon.Ok -and $recon.Rows.Count -gt 0) {
        $rr = $recon.Rows | Select-Object -First 1
        if ($rr -is [string]) {
            Add-Result -Area 'Jobs' -Check 'last reconciliation run' -Status 'Pass' -Detail "$rr"
        }
        else {
            $hrs = [int]$rr.HoursAgo
            Add-Result -Area 'Jobs' -Check 'last reconciliation run' `
                -Status $(if ($hrs -le 26) { 'Pass' } else { 'Warn' }) `
                -Detail "RunId $($rr.RunId), $hrs h ago, outcome $($rr.Outcome)" `
                -Remediation $(if ($hrs -le 26) { '' } else { 'The nightly job has not run in over a day. Check SQL Agent or the Scheduled Task.' })
        }
    }
    else {
        Add-Result -Area 'Jobs' -Check 'last reconciliation run' -Status 'Warn' `
            -Detail 'ops.ReconciliationLog is empty' `
            -Remediation 'Run: EXEC ops.usp_ReconcileOrderTotals @FailOnVariance = 0;'
    }
}

#===========================================================================
# 5. SQL Agent jobs, or the Scheduled Task stand-ins on Express
#===========================================================================
$isExpress = "$sqlEdition" -like '*Express*'

if (-not $sqlUp.Ok) {
    Add-Result -Area 'Jobs' -Check 'SQL Agent jobs' -Status 'Skip' `
        -Detail 'SQL is unreachable' -Remediation 'Fix SQL connectivity first.'
}
elseif ($isExpress) {
    Add-Result -Area 'Jobs' -Check 'SQL Agent jobs' -Status 'Skip' `
        -Detail "edition is $sqlEdition - no SQL Agent" `
        -Remediation 'Checking the Scheduled Task stand-ins instead.'

    foreach ($taskName in $cfg.ExpectedScheduledTasks) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Add-Result -Area 'Jobs' -Check "task: $taskName" -Status 'Warn' `
                -Detail 'not registered' `
                -Remediation 'Register it with the snippet printed by sql\05_sqlagent_jobs.sql Section 4.'
            continue
        }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        $lastOk = $info.LastTaskResult -eq 0
        Add-Result -Area 'Jobs' -Check "task: $taskName" `
            -Status $(if ($task.State -eq 'Disabled') { 'Warn' } elseif ($lastOk) { 'Pass' } else { 'Fail' }) `
            -Detail "state=$($task.State) lastRun=$($info.LastRunTime) result=0x$('{0:X}' -f $info.LastTaskResult) nextRun=$($info.NextRunTime)" `
            -Remediation $(if ($lastOk) { '' } else { 'Non-zero result means the reconciliation found variances or sqlcmd failed. Check ops.ReconciliationLog.' })
    }
}
else {
    foreach ($jobName in $cfg.ExpectedAgentJobs) {
        $esc = $jobName.Replace("'", "''")
        $jq = Invoke-LabSql -Database 'msdb' -Query @"
SELECT  j.name,
        CONVERT(int, j.enabled) AS IsEnabled,
        ISNULL(CONVERT(varchar(30), ja.start_execution_date, 120), 'never') AS LastStart,
        ISNULL(CONVERT(int, jh.run_status), -1) AS LastStatus,
        ISNULL(jh.message, '') AS LastMessage
FROM    msdb.dbo.sysjobs j
OUTER APPLY (SELECT TOP 1 * FROM msdb.dbo.sysjobactivity a
             WHERE a.job_id = j.job_id ORDER BY a.session_id DESC) ja
OUTER APPLY (SELECT TOP 1 * FROM msdb.dbo.sysjobhistory h
             WHERE h.job_id = j.job_id AND h.step_id = 0
             ORDER BY h.instance_id DESC) jh
WHERE   j.name = '$esc'
"@
        if (-not $jq.Ok) {
            Add-Result -Area 'Jobs' -Check "job: $jobName" -Status 'Warn' -Detail $jq.Error `
                -Remediation 'Needs rights in msdb (SQLAgentReaderRole or sysadmin).'
            continue
        }
        if ($jq.Rows.Count -eq 0) {
            Add-Result -Area 'Jobs' -Check "job: $jobName" -Status 'Fail' `
                -Detail 'job does not exist' -Remediation 'Run sql\05_sqlagent_jobs.sql.'
            continue
        }

        $j = $jq.Rows | Select-Object -First 1
        if ($j -is [string]) {
            Add-Result -Area 'Jobs' -Check "job: $jobName" -Status 'Pass' -Detail "$j"
            continue
        }

        $statusText = switch ([int]$j.LastStatus) {
            0       { 'Failed' }
            1       { 'Succeeded' }
            2       { 'Retry' }
            3       { 'Cancelled' }
            4       { 'In progress' }
            default { 'no history' }
        }
        $status = if ([int]$j.IsEnabled -eq 0) { 'Warn' }
                  elseif ([int]$j.LastStatus -eq 0) { 'Fail' }
                  elseif ([int]$j.LastStatus -eq 1) { 'Pass' }
                  else { 'Warn' }

        Add-Result -Area 'Jobs' -Check "job: $jobName" -Status $status `
            -Detail "enabled=$($j.IsEnabled) lastStart=$($j.LastStart) lastOutcome=$statusText" `
            -Remediation $(
                if ($status -eq 'Fail') { "Read the step history: see sql\03_investigate.sql Section 10b. Message: $($j.LastMessage)" }
                elseif ([int]$j.IsEnabled -eq 0) { "Job is disabled: EXEC msdb.dbo.sp_update_job @job_name='$jobName', @enabled=1" }
                else { '' })
    }

    # Any lab job currently failing, beyond the two expected ones.
    $failing = Invoke-LabSql -Database 'msdb' -Query @"
SELECT COUNT(*) AS FailedRuns FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0 AND h.run_status = 0
  AND h.run_date >= CONVERT(int, FORMAT(DATEADD(day, -1, GETDATE()), 'yyyyMMdd'))
"@
    if ($failing.Ok) {
        $f = $failing.Rows | Select-Object -First 1
        $n = if ($f -is [string]) { [int]($f -replace '\D', '') } else { [int]$f.FailedRuns }
        Add-Result -Area 'Jobs' -Check 'job failures in last 24h' `
            -Status $(if ($n -eq 0) { 'Pass' } else { 'Warn' }) -Detail "$n failed run(s)"
    }
}

#===========================================================================
# 6. Event log - the entries these four failures actually produce
#===========================================================================
if ($IncludeEventLog -and $isAdmin) {
    $since = (Get-Date).AddHours(-$EventLogHours)

    # WAS 5021: identity is invalid. 5057/5059: pool disabled after failures.
    # 5002: pool stopped by rapid-fail protection.
    $wasIds = @(5021, 5057, 5059, 5002, 5074, 5186)
    $was = @()
    try {
        $was = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS'; StartTime = $since
        } -ErrorAction Stop | Where-Object { $wasIds -contains $_.Id })
    } catch {}

    if ($was.Count -eq 0) {
        Add-Result -Area 'System' -Check "WAS app-pool events (last ${EventLogHours}h)" `
            -Status 'Pass' -Detail 'none'
    }
    else {
        $top = $was | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $ids = ($was | Group-Object Id | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
        $rem = if ($was.Id -contains 5021) {
            'Event 5021 = the app-pool identity is invalid. runbooks/01-bad-service-account-password.md'
        } elseif ($was.Id -contains 5002) {
            'Event 5002 = rapid-fail protection stopped the pool. runbooks/02-stopped-app-pool.md'
        } else {
            'runbooks/02-stopped-app-pool.md'
        }
        Add-Result -Area 'System' -Check "WAS app-pool events (last ${EventLogHours}h)" `
            -Status 'Fail' -Detail "$($was.Count) event(s): $ids | latest $($top.TimeCreated): $($top.Message -replace '\s+', ' ')" `
            -Remediation $rem
    }

    # Account lockout / bad password at the Windows level (failure 1).
    $logonFails = @()
    try {
        $logonFails = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Security'; Id = @(4625, 4740); StartTime = $since
        } -ErrorAction Stop | Where-Object { $_.Message -like "*$($cfg.ServiceAccountName)*" })
    } catch {}

    Add-Result -Area 'System' -Check "failed logons for $($cfg.ServiceAccountName) (last ${EventLogHours}h)" `
        -Status $(if ($logonFails.Count -eq 0) { 'Pass' } else { 'Fail' }) `
        -Detail $(if ($logonFails.Count -eq 0) { 'none' } else { "$($logonFails.Count) event(s), latest $(($logonFails | Select-Object -First 1).TimeCreated)" }) `
        -Remediation $(if ($logonFails.Count -eq 0) { '' } else { 'Event 4625 = bad password; 4740 = account locked out. runbooks/01-bad-service-account-password.md' })

    # Is the account locked or expired right now?
    if ($cfg.ServiceAccount.StartsWith('.\')) {
        $lu = Get-LocalUser -Name $cfg.ServiceAccountName -ErrorAction SilentlyContinue
        if ($lu) {
            $expired = $lu.PasswordExpires -and $lu.PasswordExpires -lt (Get-Date)
            $problem = (-not $lu.Enabled) -or $expired
            Add-Result -Area 'System' -Check "account $($cfg.ServiceAccountName)" `
                -Status $(if ($problem) { 'Fail' } else { 'Pass' }) `
                -Detail "enabled=$($lu.Enabled) passwordExpires=$($lu.PasswordExpires) lastPasswordSet=$($lu.PasswordLastSet)" `
                -Remediation $(if ($problem) { 'Account is disabled or its password has expired. runbooks/01-bad-service-account-password.md' } else { '' })
        }
        else {
            Add-Result -Area 'System' -Check "account $($cfg.ServiceAccountName)" -Status 'Fail' `
                -Detail 'local account not found' -Remediation 'Run New-LabServiceAccount.ps1.'
        }
    }
}
elseif ($IncludeEventLog) {
    Add-Result -Area 'System' -Check 'event log' -Status 'Skip' `
        -Detail 'needs an elevated session' -Remediation 'Re-run as Administrator.'
}

#===========================================================================
# 7. System basics worth ruling out before anything clever
#===========================================================================
$sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
if ($sysDrive) {
    $freeGb = [math]::Round($sysDrive.Free / 1GB, 1)
    $pct = if (($sysDrive.Used + $sysDrive.Free) -gt 0) {
        [math]::Round(100 * $sysDrive.Free / ($sysDrive.Used + $sysDrive.Free), 1)
    } else { 0 }
    Add-Result -Area 'System' -Check "$($env:SystemDrive) free space" `
        -Status $(if ($freeGb -lt 2) { 'Fail' } elseif ($freeGb -lt 5) { 'Warn' } else { 'Pass' }) `
        -Detail "$freeGb GB free ($pct%)" `
        -Remediation $(if ($freeGb -lt 5) { 'SQL and IIS both fail in confusing ways when the system drive fills.' } else { '' })
}

$logFolderWritable = $false
try {
    $probe = Join-Path $cfg.LogPath ".healthcheck-$PID.tmp"
    Set-Content -Path $probe -Value 'probe' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    $logFolderWritable = $true
} catch {}
Add-Result -Area 'System' -Check 'log folder writable' `
    -Status $(if ($logFolderWritable) { 'Pass' } else { 'Warn' }) `
    -Detail "$($cfg.LogPath) writable by $([Environment]::UserName)=$logFolderWritable" `
    -Remediation $(if ($logFolderWritable) { '' } else { 'This is your account, not the app pool identity; check the pool identity has Modify. runbooks/04-permission-denied.md' })

#===========================================================================
# output
#===========================================================================
$fails = @($results | Where-Object Status -eq 'Fail')
$warns = @($results | Where-Object Status -eq 'Warn')

if ($Json) {
    [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Computer     = $env:COMPUTERNAME
        Site         = $cfg.SiteName
        SqlInstance  = $cfg.SqlInstance
        AppIdentity  = $appIdentity
        SqlEdition   = $sqlEdition
        Summary      = [pscustomobject]@{
            Pass = @($results | Where-Object Status -eq 'Pass').Count
            Warn = $warns.Count
            Fail = $fails.Count
            Skip = @($results | Where-Object Status -eq 'Skip').Count
        }
        Results      = $results
    } | ConvertTo-Json -Depth 5
}
elseif (-not $Quiet) {
    Write-Host ''
    Write-Host "OrderDesk health check - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
    Write-Host ('-' * 100)

    foreach ($group in $results | Group-Object Area) {
        Write-Host ''
        Write-Host $group.Name.ToUpper() -ForegroundColor White
        foreach ($r in $group.Group) {
            $colour = switch ($r.Status) {
                'Pass' { 'Green' } 'Warn' { 'Yellow' } 'Fail' { 'Red' } 'Skip' { 'DarkGray' }
            }
            Write-Host ('  {0,-6}' -f $r.Status) -ForegroundColor $colour -NoNewline
            Write-Host ('{0,-38} {1}' -f $r.Check, $r.Detail)
            if ($r.Remediation) {
                Write-Host ('         -> {0}' -f $r.Remediation) -ForegroundColor DarkCyan
            }
        }
    }

    Write-Host ''
    Write-Host ('-' * 100)
    $summary = "Pass $(@($results | Where-Object Status -eq 'Pass').Count)  " +
               "Warn $($warns.Count)  Fail $($fails.Count)  " +
               "Skip $(@($results | Where-Object Status -eq 'Skip').Count)"
    Write-Host $summary -ForegroundColor $(if ($fails.Count) { 'Red' } elseif ($warns.Count) { 'Yellow' } else { 'Green' })

    if ($fails.Count -gt 0) {
        Write-Host ''
        Write-Host 'Start here:' -ForegroundColor Red
        foreach ($f in $fails) {
            Write-Host "  [$($f.Area)] $($f.Check): $($f.Detail)"
            if ($f.Remediation) { Write-Host "      $($f.Remediation)" -ForegroundColor DarkCyan }
        }
    }
}

exit $fails.Count
