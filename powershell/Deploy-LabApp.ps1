<#
.SYNOPSIS
    Deploys OrderDesk to IIS and builds the AppSupportLab database.

.DESCRIPTION
    Idempotent end to end. Steps:
      1. copy app\ to the site path
      2. pip install the app's requirements into the system Python
      3. rewrite web.config for this machine's paths and SQL instance
      4. create or update the app pool, running as the service account
      5. create or update the website and its binding
      6. set NTFS ACLs: read+execute on content, modify on logs only
      7. run sql\01..06 against the SQL instance
      8. recycle, then prove the site answers /health

.PARAMETER ServiceAccountCredential
    The app-pool identity. Prompted for when omitted. The user name must match
    LabConfig.ServiceAccount; only the password is read from here.

.PARAMETER SkipDatabase
    Deploy the web tier only.

.PARAMETER SkipPip
    Do not touch site-packages (offline VM, or already installed).

.EXAMPLE
    .\Deploy-LabApp.ps1
.EXAMPLE
    .\Deploy-LabApp.ps1 -SkipDatabase
#>
[CmdletBinding()]
param(
    [System.Management.Automation.PSCredential]$ServiceAccountCredential,
    [switch]$SkipDatabase,
    [switch]$SkipPip
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.config.ps1"
Assert-LabAdmin
$cfg = Get-LabConfig

Import-Module WebAdministration -ErrorAction Stop

$srcApp = Join-Path $cfg.RepoRoot 'app'
$srcSql = Join-Path $cfg.RepoRoot 'sql'
if (-not (Test-Path $srcApp)) { throw "Cannot find the app folder at $srcApp" }

$isLocal   = $cfg.ServiceAccount.StartsWith('.\')
$qualified = if ($isLocal) { "$env:COMPUTERNAME\$($cfg.ServiceAccountName)" } else { $cfg.ServiceAccount }

if (-not $ServiceAccountCredential) {
    Write-LabInfo "Enter the password for $qualified (the app-pool identity)."
    $ServiceAccountCredential = Get-Credential -UserName $qualified `
        -Message 'OrderDesk app pool identity'
}

#---------------------------------------------------------------------------
Write-LabStep "1/8 Copying app to $($cfg.SitePath)"

New-Item -ItemType Directory -Path $cfg.SitePath -Force | Out-Null
New-Item -ItemType Directory -Path $cfg.LogPath  -Force | Out-Null

# Exclude dev-only and build artefacts; the VM runs the SQL Server backend.
$exclude = @('__pycache__', '.venv', 'logs', 'orderdesk_smoke.db')
robocopy $srcApp $cfg.SitePath /MIR /NFL /NDL /NJH /NJS /NP /XD $exclude /XF '*.pyc' | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
Write-LabOk "copied $(@(Get-ChildItem -Path $cfg.SitePath -Recurse -File).Count) file(s)"

#---------------------------------------------------------------------------
Write-LabStep '2/8 Python dependencies'

if ($SkipPip) {
    Write-LabInfo 'skipped (-SkipPip)'
}
else {
    $req = Join-Path $cfg.SitePath 'requirements.txt'
    & $cfg.PythonExe -m pip install --disable-pip-version-check --no-warn-script-location -r $req
    if ($LASTEXITCODE -ne 0) { throw "pip install failed with exit code $LASTEXITCODE" }

    # Fail now, loudly, rather than as a 502 from IIS later.
    & $cfg.PythonExe -c "import flask, pyodbc; print('flask', flask.__version__, '| pyodbc', pyodbc.version)"
    if ($LASTEXITCODE -ne 0) { throw 'flask or pyodbc is not importable by the system Python.' }
    Write-LabOk 'flask and pyodbc import cleanly'
}

#---------------------------------------------------------------------------
Write-LabStep '3/8 web.config for this machine'

$webConfigPath = Join-Path $cfg.SitePath 'web.config'
[xml]$wc = Get-Content -Path $webConfigPath

$hp = $wc.configuration.'system.webServer'.httpPlatform
$hp.processPath   = $cfg.PythonExe
$hp.arguments     = '"{0}"' -f (Join-Path $cfg.SitePath 'app.py')
$hp.stdoutLogFile = Join-Path $cfg.LogPath 'httpplatform-stdout'

function Set-LabEnvVar {
    param([xml]$Doc, [string]$Name, [string]$Value)
    $parent = $Doc.configuration.'system.webServer'.httpPlatform.environmentVariables
    $node = $parent.environmentVariable | Where-Object { $_.name -eq $Name }
    if (-not $node) {
        $node = $Doc.CreateElement('environmentVariable')
        $node.SetAttribute('name', $Name)
        $parent.AppendChild($node) | Out-Null
    }
    $node.SetAttribute('value', $Value)
}

Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_DB_BACKEND'   -Value 'mssql'
Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_SQL_SERVER'   -Value $cfg.SqlInstance
Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_SQL_DATABASE' -Value $cfg.Database
Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_SQL_DRIVER'   -Value $cfg.OdbcDriver
Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_SQL_TRUSTED'  -Value 'yes'
Set-LabEnvVar -Doc $wc -Name 'ORDERDESK_LOG_DIR'      -Value $cfg.LogPath

$wc.Save($webConfigPath)
Write-LabOk "web.config points at $($cfg.PythonExe) and $($cfg.SqlInstance)"

#---------------------------------------------------------------------------
Write-LabStep "4/8 App pool $($cfg.AppPoolName)"

if (-not (Test-Path "IIS:\AppPools\$($cfg.AppPoolName)")) {
    New-WebAppPool -Name $cfg.AppPoolName | Out-Null
    Write-LabOk 'created the app pool'
}
else {
    Write-LabOk 'app pool already exists'
}

$poolPath = "IIS:\AppPools\$($cfg.AppPoolName)"

# No managed runtime: this pool only ever hosts the Python process.
Set-ItemProperty -Path $poolPath -Name managedRuntimeVersion -Value ''
Set-ItemProperty -Path $poolPath -Name managedPipelineMode   -Value 'Integrated'
Set-ItemProperty -Path $poolPath -Name enable32BitAppOnWin64 -Value $false
Set-ItemProperty -Path $poolPath -Name startMode             -Value 'AlwaysRunning'

# identityType 3 = SpecificUser.
Set-ItemProperty -Path $poolPath -Name processModel -Value @{
    identityType  = 3
    userName      = $ServiceAccountCredential.UserName
    password      = $ServiceAccountCredential.GetNetworkCredential().Password
    idleTimeout   = [TimeSpan]::Zero       # do not idle out; keeps the lab predictable
    loadUserProfile = $true                # pyodbc and the ODBC driver want a profile
}

# Rapid-fail protection is left ON deliberately. Failure 1 and failure 3 both
# trip it, and seeing the pool stop itself after 5 crashes in 5 minutes is
# the lesson, not an inconvenience.
Set-ItemProperty -Path $poolPath -Name failure -Value @{
    rapidFailProtection              = $true
    rapidFailProtectionMaxCrashes    = 5
    rapidFailProtectionInterval      = [TimeSpan]::FromMinutes(5)
}
Set-ItemProperty -Path $poolPath -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)

Write-LabOk "identity set to $($ServiceAccountCredential.UserName)"

#---------------------------------------------------------------------------
Write-LabStep "5/8 Website $($cfg.SiteName) on port $($cfg.SitePort)"

$site = Get-Website -Name $cfg.SiteName -ErrorAction SilentlyContinue
if (-not $site) {
    New-Website -Name $cfg.SiteName -Port $cfg.SitePort -PhysicalPath $cfg.SitePath `
        -ApplicationPool $cfg.AppPoolName -Force | Out-Null
    Write-LabOk 'created the website'
}
else {
    Set-ItemProperty -Path "IIS:\Sites\$($cfg.SiteName)" -Name physicalPath    -Value $cfg.SitePath
    Set-ItemProperty -Path "IIS:\Sites\$($cfg.SiteName)" -Name applicationPool -Value $cfg.AppPoolName
    Write-LabOk 'website already exists; path and pool refreshed'
}

# Default Web Site also listens on 80; leave it alone but warn on a clash.
$clash = Get-WebBinding | Where-Object {
    $_.bindingInformation -like "*:$($cfg.SitePort):*" -and
    $_.ItemXPath -notlike "*@name='$($cfg.SiteName)'*"
}
if ($clash) { Write-LabWarn "another site is also bound to port $($cfg.SitePort)" }

#---------------------------------------------------------------------------
Write-LabStep '6/8 NTFS permissions'

function Add-LabAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Rights
    )
    $acl = Get-Acl -Path $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Account, $Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

# Content: read and execute only. The app must not be able to rewrite itself.
Add-LabAcl -Path $cfg.SitePath -Account $qualified -Rights 'ReadAndExecute'
Write-LabOk "ReadAndExecute on $($cfg.SitePath)"

# Logs: the one place the worker process may write.
Add-LabAcl -Path $cfg.LogPath -Account $qualified -Rights 'Modify'
Write-LabOk "Modify on $($cfg.LogPath)"

# IIS needs the app pool's own virtual account to read content too.
try {
    Add-LabAcl -Path $cfg.SitePath -Account "IIS AppPool\$($cfg.AppPoolName)" -Rights 'ReadAndExecute'
    Write-LabOk "ReadAndExecute for IIS AppPool\$($cfg.AppPoolName)"
}
catch {
    Write-LabInfo 'app-pool virtual account ACL not applied (expected when using a specific user)'
}

#---------------------------------------------------------------------------
Write-LabStep '7/8 Database'

if ($SkipDatabase) {
    Write-LabInfo 'skipped (-SkipDatabase)'
}
else {
    $scripts = @(
        '01_schema.sql',
        '02_seed.sql',
        '05_sqlagent_jobs.sql',
        '06_app_login_permissions.sql'
    )

    $useModule = $null -ne (Get-Module -ListAvailable -Name SqlServer)
    foreach ($s in $scripts) {
        $path = Join-Path $srcSql $s
        if (-not (Test-Path $path)) { throw "Missing SQL script: $path" }
        Write-LabInfo "running $s"

        if ($useModule) {
            Import-Module SqlServer -ErrorAction Stop
            Invoke-Sqlcmd -ServerInstance $cfg.SqlInstance -InputFile $path `
                -Variable @("LabServiceAccount=$qualified") `
                -TrustServerCertificate -QueryTimeout 300 -ErrorAction Stop |
                Out-String | Write-Host
        }
        else {
            & sqlcmd.exe -S $cfg.SqlInstance -E -b -I `
                -v "LabServiceAccount=$qualified" -i $path
            if ($LASTEXITCODE -ne 0) { throw "$s failed (sqlcmd exit code $LASTEXITCODE)" }
        }
        Write-LabOk "$s applied"
    }
    # 03 and 04 are investigation and remediation; they are run by a human, not here.
    Write-LabInfo '03_investigate.sql and 04_datafix_controlled.sql are left for you to run'
}

#---------------------------------------------------------------------------
Write-LabStep '8/8 Start and verify'

if ((Get-Service W3SVC).Status -ne 'Running') { Start-Service W3SVC }

if ((Get-WebAppPoolState -Name $cfg.AppPoolName).Value -ne 'Started') {
    Start-WebAppPool -Name $cfg.AppPoolName
}
else {
    Restart-WebAppPool -Name $cfg.AppPoolName
}
Start-Sleep -Seconds 3

$ok = $false
foreach ($attempt in 1..10) {
    try {
        $r = Invoke-WebRequest -Uri $cfg.HealthUrl -UseBasicParsing -TimeoutSec 10
        $body = $r.Content | ConvertFrom-Json
        Write-LabOk "HTTP $($r.StatusCode) - status=$($body.status) identity=$($body.identity)"
        $ok = $true
        break
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp -and $resp.StatusCode.value__ -eq 503) {
            # The app answered, so IIS and Python are fine; SQL is not.
            Write-LabWarn 'app is up but reports degraded (HTTP 503) - database dependency is failing'
            Write-LabInfo 'run .\Invoke-LabHealthCheck.ps1 for the detail'
            $ok = $true
            break
        }
        Write-LabInfo "attempt $attempt/10: $($_.Exception.Message)"
        Start-Sleep -Seconds 3
    }
}

if (-not $ok) {
    Write-LabFail "no answer from $($cfg.HealthUrl)"
    Write-LabInfo "check $($cfg.LogPath)\httpplatform-stdout*.log and the Application event log"
    Write-LabInfo 'then run .\Invoke-LabHealthCheck.ps1'
    exit 1
}

Write-LabStep 'Deployment complete'
Write-LabInfo "site        : http://localhost:$($cfg.SitePort)/"
Write-LabInfo "health      : $($cfg.HealthUrl)"
Write-LabInfo "diagnostics : $($cfg.DiagUrl)"
Write-LabInfo ''
Write-LabInfo 'Next:  .\Invoke-LabHealthCheck.ps1'
Write-LabInfo 'Then:  .\Invoke-LabBreak.ps1 -Scenario BadServiceAccountPassword'
