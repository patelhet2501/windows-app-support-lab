<#
    lab.config.ps1 - one place for every name and path the lab uses.

    Dot-source it:   . "$PSScriptRoot\lab.config.ps1"

    No password lives here. Scripts that need the service-account password
    prompt for it (Get-Credential / Read-Host -AsSecureString) so it is never
    written to disk, a transcript, or your shell history.
#>

$LabConfig = [ordered]@{

    # --- identity ---------------------------------------------------------
    # Workgroup VM: use ".\svc_orderdesk" (local account).
    # Domain VM:    use "LABNET\svc_orderdesk" and create the account in AD.
    ServiceAccount     = '.\svc_orderdesk'
    ServiceAccountName = 'svc_orderdesk'
    ServiceAccountDesc = 'OrderDesk IIS app pool and SQL access'

    # --- IIS --------------------------------------------------------------
    SiteName    = 'OrderDesk'
    AppPoolName = 'OrderDeskPool'
    SitePort    = 8080
    SitePath    = 'C:\inetpub\OrderDesk'
    LogPath     = 'C:\inetpub\OrderDesk\logs'

    # --- app --------------------------------------------------------------
    PythonExe   = 'C:\Python312\python.exe'
    HealthUrl   = 'http://localhost:8080/health'
    DiagUrl     = 'http://localhost:8080/diag'

    # --- SQL --------------------------------------------------------------
    SqlInstance   = 'localhost\SQLEXPRESS'
    SqlServiceName = 'MSSQL$SQLEXPRESS'
    SqlAgentServiceName = 'SQLAgent$SQLEXPRESS'
    SqlBrowserServiceName = 'SQLBrowser'
    Database      = 'AppSupportLab'
    OdbcDriver    = 'ODBC Driver 18 for SQL Server'
    # Jobs the health check expects to exist (Developer/Standard edition only).
    ExpectedAgentJobs = @(
        'AppSupportLab - Nightly Order Reconciliation',
        'AppSupportLab - Weekly Audit Purge'
    )
    # Scheduled-task stand-ins used on Express edition.
    ExpectedScheduledTasks = @(
        'AppSupportLab - Nightly Order Reconciliation'
    )

    # --- services the health check watches --------------------------------
    WatchedServices = @('W3SVC', 'WAS', 'MSSQL$SQLEXPRESS')

    # --- lab bookkeeping --------------------------------------------------
    StateFile  = 'C:\LabState\orderdesk-break-state.json'
    RepoRoot   = (Split-Path -Parent $PSScriptRoot)
}

function Get-LabConfig { $script:LabConfig }

function Assert-LabAdmin {
    <#  Most of this lab needs an elevated session; fail early and clearly. #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run in an elevated PowerShell session (Run as Administrator).'
    }
}

function Write-LabStep {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-LabOk   { param([string]$Message) Write-Host "    [ ok ] $Message" -ForegroundColor Green }
function Write-LabWarn { param([string]$Message) Write-Host "    [warn] $Message" -ForegroundColor Yellow }
function Write-LabFail  { param([string]$Message) Write-Host "    [fail] $Message" -ForegroundColor Red }
function Write-LabInfo  { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
