<#
.SYNOPSIS
    Installs the Windows Server roles and software the OrderDesk lab needs.

.DESCRIPTION
    Idempotent. Run it repeatedly; it installs only what is missing.

    Installs, in order:
      1. IIS with the management and tracing features support work needs
      2. HttpPlatformHandler (the IIS module that hosts the Python process)
      3. Python 3.12
      4. Microsoft ODBC Driver 18 for SQL Server
      5. SQL Server Express (or Developer, with -SqlEdition Developer)
      6. firewall rule for the site port

    Installers are not bundled. Either let the script download them, or stage
    them in -InstallerPath beforehand for an offline VM.

.PARAMETER InstallerPath
    Folder holding (or receiving) the installers.

.PARAMETER SqlSetupPath
    Path to SQL Server setup.exe or the SQL Express bootstrapper. SQL is
    skipped when this is not supplied and no instance is present.

.PARAMETER SqlEdition
    Express (default) or Developer. Developer is free and, unlike Express,
    includes SQL Server Agent - needed for the SQL Agent half of the lab.

.PARAMETER SkipDownload
    Never reach the internet; require every installer to be staged already.

.EXAMPLE
    .\Install-LabPrereqs.ps1 -SqlEdition Developer -SqlSetupPath D:\SQL\setup.exe
#>
[CmdletBinding()]
param(
    [string]$InstallerPath = 'C:\LabInstallers',
    [string]$SqlSetupPath,
    [ValidateSet('Express', 'Developer')]
    [string]$SqlEdition = 'Express',
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lab.config.ps1"
Assert-LabAdmin
$cfg = Get-LabConfig

# Download URLs. Microsoft moves these from time to time; if a download 404s,
# fetch the installer by hand and drop it in $InstallerPath under this name.
$downloads = @{
    'httpplatformhandler.msi' = 'https://download.microsoft.com/download/A/A/E/AAE7A3AD-CE55-4C8A-B080-E9A41FF6C6B0/httpplatformhandler_amd64.msi'
    'python-installer.exe'    = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe'
    'msodbcsql18.msi'         = 'https://go.microsoft.com/fwlink/?linkid=2249004'
    'sqlexpress-setup.exe'    = 'https://go.microsoft.com/fwlink/?linkid=866658'
}

New-Item -ItemType Directory -Path $InstallerPath -Force | Out-Null

function Get-LabInstaller {
    param([Parameter(Mandatory)][string]$Name)

    $target = Join-Path $InstallerPath $Name
    if (Test-Path $target) {
        Write-LabInfo "using staged $Name"
        return $target
    }
    if ($SkipDownload) {
        throw "$Name is not staged in $InstallerPath and -SkipDownload was given."
    }
    if (-not $downloads.ContainsKey($Name)) {
        throw "No download URL known for $Name."
    }
    Write-LabInfo "downloading $Name ..."
    try {
        # TLS 1.2 is not the default on older Windows Server builds.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloads[$Name] -OutFile $target -UseBasicParsing
    }
    catch {
        throw "Could not download $Name ($($_.Exception.Message)). Stage it in $InstallerPath and re-run."
    }
    return $target
}

function Invoke-LabInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$SuccessCodes = @(0, 3010)       # 3010 = success, reboot required
    )
    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($SuccessCodes -notcontains $p.ExitCode) {
        throw "$(Split-Path -Leaf $Path) failed with exit code $($p.ExitCode)."
    }
    if ($p.ExitCode -eq 3010) { Write-LabWarn 'installer requests a reboot' }
    return $p.ExitCode
}

#---------------------------------------------------------------------------
Write-LabStep '1/6 IIS and its management tools'

$features = @(
    'Web-Server',
    'Web-WebServer',
    'Web-Common-Http',
    'Web-Default-Doc',
    'Web-Static-Content',
    'Web-Http-Errors',
    'Web-Http-Logging',
    'Web-Request-Monitor',   # worker-process requests, for diagnosing hangs
    'Web-Http-Tracing',      # failed request tracing
    'Web-Stat-Compression',
    'Web-Filtering',
    'Web-Mgmt-Console',
    'Web-Mgmt-Tools',
    'Web-Scripting-Tools'    # the WebAdministration PowerShell module
)

$missing = @()
foreach ($f in $features) {
    $state = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    if ($null -eq $state) { Write-LabWarn "feature $f not available on this SKU"; continue }
    if (-not $state.Installed) { $missing += $f }
}

if ($missing.Count -gt 0) {
    Write-LabInfo "installing: $($missing -join ', ')"
    $r = Install-WindowsFeature -Name $missing -IncludeManagementTools
    if (-not $r.Success) { throw "Install-WindowsFeature failed: $($r.ExitCode)" }
    if ($r.RestartNeeded -eq 'Yes') { Write-LabWarn 'IIS install wants a reboot; finish the lab after rebooting' }
    Write-LabOk "installed $($missing.Count) feature(s)"
}
else {
    Write-LabOk 'all IIS features already present'
}

#---------------------------------------------------------------------------
Write-LabStep '2/6 HttpPlatformHandler'

$hphInstalled = Test-Path 'C:\Windows\System32\inetsrv\httpPlatformHandler.dll'
if (-not $hphInstalled) {
    # The module may also be registered under a different path; check IIS too.
    $hphInstalled = $null -ne (Get-WebGlobalModule -ErrorAction SilentlyContinue |
                               Where-Object Name -eq 'httpPlatformHandler')
}

if ($hphInstalled) {
    Write-LabOk 'HttpPlatformHandler already installed'
}
else {
    $msi = Get-LabInstaller 'httpplatformhandler.msi'
    Invoke-LabInstaller -Path 'msiexec.exe' -Arguments @('/i', "`"$msi`"", '/quiet', '/norestart')
    Write-LabOk 'HttpPlatformHandler installed'
}

#---------------------------------------------------------------------------
Write-LabStep '3/6 Python'

if (Test-Path $cfg.PythonExe) {
    $ver = & $cfg.PythonExe '--version'
    Write-LabOk "Python already present: $ver"
}
else {
    $exe = Get-LabInstaller 'python-installer.exe'
    # InstallAllUsers so the app-pool identity can see it; no PATH change, the
    # web.config names the interpreter by full path on purpose.
    Invoke-LabInstaller -Path $exe -Arguments @(
        '/quiet', 'InstallAllUsers=1', 'PrependPath=0', 'Include_test=0',
        'Include_launcher=1', "TargetDir=$(Split-Path -Parent $cfg.PythonExe)"
    )
    if (-not (Test-Path $cfg.PythonExe)) {
        throw "Python installed but $($cfg.PythonExe) is missing. Check TargetDir and update lab.config.ps1."
    }
    Write-LabOk "Python installed to $($cfg.PythonExe)"
}

#---------------------------------------------------------------------------
Write-LabStep '4/6 ODBC Driver 18 for SQL Server'

$haveDriver = (Get-OdbcDriver -ErrorAction SilentlyContinue |
               Where-Object Name -eq $cfg.OdbcDriver)
if ($haveDriver) {
    Write-LabOk "$($cfg.OdbcDriver) already installed"
}
else {
    $msi = Get-LabInstaller 'msodbcsql18.msi'
    Invoke-LabInstaller -Path 'msiexec.exe' -Arguments @(
        '/i', "`"$msi`"", '/quiet', '/norestart', 'IACCEPTMSODBCSQLLICENSETERMS=YES'
    )
    Write-LabOk 'ODBC Driver 18 installed'
}

#---------------------------------------------------------------------------
Write-LabStep "5/6 SQL Server ($SqlEdition)"

$sqlService = Get-Service -Name $cfg.SqlServiceName -ErrorAction SilentlyContinue
if ($sqlService) {
    Write-LabOk "$($cfg.SqlServiceName) already installed (status: $($sqlService.Status))"
    if ($sqlService.Status -ne 'Running') {
        Start-Service -Name $cfg.SqlServiceName
        Write-LabOk 'started the SQL Server service'
    }
}
elseif (-not $SqlSetupPath) {
    Write-LabWarn 'No SQL instance found and -SqlSetupPath was not supplied.'
    Write-LabInfo 'SQL Express bootstrapper (downloads the real media):'
    Write-LabInfo '  https://go.microsoft.com/fwlink/?linkid=866658'
    Write-LabInfo 'SQL Developer edition (free, and the only way to get SQL Agent):'
    Write-LabInfo '  https://www.microsoft.com/en-us/sql-server/sql-server-downloads'
    Write-LabInfo 'Then re-run:  .\Install-LabPrereqs.ps1 -SqlSetupPath <path to setup.exe>'
}
else {
    if (-not (Test-Path $SqlSetupPath)) { throw "SQL setup not found at $SqlSetupPath" }

    # The installing admin becomes sysadmin so the lab SQL scripts can run.
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $sqlArgs = @(
        '/Q', '/ACTION=Install', '/IACCEPTSQLSERVERLICENSETERMS',
        '/FEATURES=SQLENGINE',
        '/INSTANCENAME=SQLEXPRESS',
        '/SECURITYMODE=SQL',                  # mixed mode, so sa exists for job owners
        '/TCPENABLED=1',
        '/NPENABLED=1',
        "/SQLSYSADMINACCOUNTS=`"$me`"",
        '/SQLSVCSTARTUPTYPE=Automatic',
        '/BROWSERSVCSTARTUPTYPE=Automatic',
        '/AGTSVCSTARTUPTYPE=Automatic'
    )

    Write-LabWarn 'SQL setup needs the sa password and will prompt for it now.'
    $saPwd = Read-Host -Prompt '  sa password' -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni(
                 [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPwd))
    try {
        $sqlArgs += "/SAPWD=`"$plain`""
        Write-LabInfo 'running SQL setup, this takes several minutes ...'
        Invoke-LabInstaller -Path $SqlSetupPath -Arguments $sqlArgs
    }
    finally {
        # Do not leave the password in a variable any longer than needed.
        $plain = $null
        [GC]::Collect()
    }
    Write-LabOk 'SQL Server installed'
}

# SQL Browser matters as soon as you connect by instance name from elsewhere.
$browser = Get-Service -Name $cfg.SqlBrowserServiceName -ErrorAction SilentlyContinue
if ($browser -and $browser.StartType -eq 'Disabled') {
    Set-Service -Name $cfg.SqlBrowserServiceName -StartupType Automatic
    Start-Service -Name $cfg.SqlBrowserServiceName
    Write-LabOk 'enabled and started SQL Browser'
}

# Note the Agent situation plainly; the lab depends on knowing this.
$edition = $null
try {
    $edition = (Invoke-Sqlcmd -ServerInstance $cfg.SqlInstance `
                -Query "SELECT CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS Edition" `
                -TrustServerCertificate -ErrorAction Stop).Edition
}
catch { Write-LabInfo 'could not query the edition yet (SqlServer module may be missing)' }

if ($edition) {
    Write-LabInfo "SQL edition: $edition"
    if ($edition -like '*Express*') {
        Write-LabWarn 'Express edition has no working SQL Server Agent.'
        Write-LabInfo 'sql\05_sqlagent_jobs.sql will skip the jobs and print a Scheduled Task equivalent.'
    }
}

#---------------------------------------------------------------------------
Write-LabStep '6/6 firewall and PowerShell modules'

$ruleName = "OrderDesk HTTP $($cfg.SitePort)"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
        -LocalPort $cfg.SitePort -Action Allow -Profile Any | Out-Null
    Write-LabOk "opened TCP $($cfg.SitePort)"
}
else {
    Write-LabOk "firewall rule '$ruleName' already present"
}

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-LabInfo 'installing the SqlServer PowerShell module (used by the health check)'
    try {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
        Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber
        Write-LabOk 'SqlServer module installed'
    }
    catch {
        Write-LabWarn "could not install the SqlServer module: $($_.Exception.Message)"
        Write-LabInfo 'the health check falls back to sqlcmd.exe when the module is absent'
    }
}
else {
    Write-LabOk 'SqlServer module already available'
}

Write-LabStep 'Prerequisites complete'
Write-LabInfo 'Next:  .\New-LabServiceAccount.ps1   then   .\Deploy-LabApp.ps1'
