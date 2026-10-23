# Runbook 03 — Bad connection string

**Severity**: partial outage. The site serves; every data screen fails.
**Typical cause**: a config edited by hand between environments — wrong
instance name, wrong database, a typo, or a driver that is not installed.

---

## Symptom

- The site **loads**. The landing page renders. So IIS, the app pool and the
  app itself are all fine — that alone rules out runbooks 01 and 02.
- `/orders`, `/discrepancies` and `/audit` show **"Database unavailable"**.
- `/health` returns **HTTP 503** with `status: degraded` and
  `checks.database.detail.kind` of `unreachable` (or `missing_object` when the
  server is right and the database is wrong).
- **SQL Server shows no failed logins**, because no connection ever arrived.
  That absence is the whole diagnosis: compare with runbook 01, where the
  Windows logon fails, and runbook 04, where SQL logs a refusal.

## Impact

Read and write of order data. The app stays up and reports the failure
honestly, which is why it is partial rather than total.

---

## Triage (2 minutes)

```powershell
Invoke-RestMethod http://localhost:8080/health -SkipHttpErrorCheck |
    ConvertTo-Json -Depth 5
```

(On PowerShell 5.1, which has no `-SkipHttpErrorCheck`:)

```powershell
try { Invoke-RestMethod http://localhost:8080/health }
catch { $_.ErrorDetails.Message }
```

Read `kind`:

| `kind` | SQL error | Meaning |
|---|---|---|
| `unreachable` | 08001 / 08S01 | server or instance name is wrong, or SQL is down |
| `missing_object` | 208 | connected, but this database has no `app.Orders` |
| `login_failed` | 18456 / 4060 | SQL rejected the login → runbook 01 or 04 |
| `other` | IM002 | the named ODBC driver is not installed |

Then see exactly what the app is using:

```powershell
Invoke-RestMethod http://localhost:8080/diag | Select-Object -ExpandProperty connection_string
```

The password is redacted; the server and database names are not. Compare them
against reality, character by character — this failure is usually one letter.

---

## Diagnosis

### 1. What does the app think it is connecting to?

```powershell
[xml]$wc = Get-Content C:\inetpub\OrderDesk\web.config
$wc.configuration.'system.webServer'.httpPlatform.environmentVariables.environmentVariable |
    Where-Object name -like 'ORDERDESK_SQL*' |
    Select-Object name, value | Format-Table -AutoSize
```

### 2. What is actually there?

```powershell
Get-Service | Where-Object Name -like 'MSSQL*' |
    Select-Object Name, Status, StartType
```

The service name carries the instance name: `MSSQL$SQLEXPRESS` is instance
`SQLEXPRESS`. `localhost\SQLEXPRES` (one S short) has no service and no
listener — the app's error is literally correct.

List instances from the registry:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -Name InstalledInstances |
    Select-Object -ExpandProperty InstalledInstances
```

### 3. Can anything connect, independent of the app?

```powershell
sqlcmd -S localhost\SQLEXPRESS -E -Q "SELECT @@SERVERNAME AS ServerName, DB_NAME() AS Db"
```

- Works → the instance is fine; the app's string is wrong.
- Fails the same way → the problem is SQL or the network, not the config.

Try the app's exact string:

```powershell
sqlcmd -S "localhost\SQLEXPRES" -E -Q "SELECT 1"
# expect: Could not open a connection to SQL Server
```

### 4. Named instances need SQL Browser

Connecting by *instance name* (not port) requires the browser service to
resolve it:

```powershell
Get-Service SQLBrowser | Select-Object Name, Status, StartType
```

Stopped browser → named-instance connections fail while
`localhost,1433`-style connections still work. A classic "it works from the
server but not from the app" cause.

### 5. Is the database the right one?

```powershell
sqlcmd -S localhost\SQLEXPRESS -E -Q "SELECT name, state_desc FROM sys.databases ORDER BY name"
sqlcmd -S localhost\SQLEXPRESS -d AppSupportLab -E -Q "SELECT COUNT(*) AS Orders FROM app.Orders"
```

`kind = missing_object` with a working connection means the server name is
right and the database name is not.

### 6. Is the ODBC driver present?

```powershell
Get-OdbcDriver | Where-Object Name -like '*SQL Server*' | Select-Object Name
```

The name in the connection string must match one of these *exactly*, braces
and version included: `ODBC Driver 18 for SQL Server`. Driver 18 also
defaults to `Encrypt=yes`, so a server with a self-signed certificate needs
`TrustServerCertificate=yes` — otherwise you get a certificate error that
reads like a network failure.

### 7. Protocols and port, if the instance is remote

```powershell
Test-NetConnection -ComputerName localhost -Port 1433
# TCP may be disabled on a fresh Express install:
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*.SQLEXPRESS\MSSQLServer\SuperSocketNetLib\Tcp' `
    -Name Enabled -ErrorAction SilentlyContinue
```

---

## Root cause

The app resolves its connection string from `ORDERDESK_SQL_*` environment
variables set by `web.config`. One of them names something that does not
exist. IIS passes those variables to the child process **only at process
start**, so an edit has no effect until the pool recycles — which is also why
"I fixed the config and nothing changed" is so common here.

---

## Fix

### 1. Confirm the correct target *before* editing anything

```powershell
sqlcmd -S localhost\SQLEXPRESS -d AppSupportLab -E -Q "SELECT @@SERVERNAME, DB_NAME()"
```

Never put an unverified value into a config.

### 2. Correct the setting

```powershell
$path = 'C:\inetpub\OrderDesk\web.config'
[xml]$wc = Get-Content $path
$node = $wc.configuration.'system.webServer'.httpPlatform.environmentVariables.environmentVariable |
        Where-Object name -eq 'ORDERDESK_SQL_SERVER'
$node.SetAttribute('value', 'localhost\SQLEXPRESS')
$wc.Save($path)
```

### 3. Recycle so the new environment is read

```powershell
Restart-WebAppPool -Name OrderDeskPool
```

This step is not optional.

### 4. If the cause was elsewhere

```powershell
Start-Service 'MSSQL$SQLEXPRESS'                      # SQL was down
Set-Service SQLBrowser -StartupType Automatic; Start-Service SQLBrowser
# missing driver: install msodbcsql18, then recycle the pool
```

---

## Verify

```powershell
Invoke-RestMethod http://localhost:8080/health | ConvertTo-Json -Depth 5
```

Expect `status: healthy`, `checks.database.ok: true`, and a sane
`latency_ms`. Then exercise a real query path, not just the probe:

```powershell
(Invoke-RestMethod http://localhost:8080/api/orders).Count     # 12 after seeding
Invoke-RestMethod http://localhost:8080/diag | Select-Object -ExpandProperty connection_string
```

And confirm it survives a recycle, which proves the change is in the config
and not just in a lucky running process:

```powershell
Restart-WebAppPool -Name OrderDeskPool
Start-Sleep -Seconds 6
(Invoke-WebRequest http://localhost:8080/health -UseBasicParsing).StatusCode   # 200
```

```powershell
.\Invoke-LabHealthCheck.ps1
```

---

## Rollback

`Invoke-LabBreak.ps1` recorded the previous value:

```powershell
Get-Content C:\LabState\orderdesk-break-state.json | ConvertFrom-Json |
    Select-Object -ExpandProperty Broken |
    Where-Object Scenario -eq 'BadConnectionString' |
    Select-Object -ExpandProperty Before
```

Otherwise re-run `Deploy-LabApp.ps1`, which regenerates `web.config` from
`app\web.config` plus `lab.config.ps1`. Keep `web.config` in source control
so a known-good version is always one `git diff` away.

---

## Prevention

- Keep `web.config` in source control; deploy it, never hand-edit it on the
  server. `Deploy-LabApp.ps1` is the pattern: template in the repo, values
  from config.
- Make the app *report* its dependency configuration (`/diag` here, with the
  password redacted). Hours get lost guessing what a service is pointed at.
- Health-check the dependency, not just the process — a 200 that never touches
  SQL tells you nothing.
- Keep the failure classification in the app (`kind` here) so the 503 names
  the layer at fault.
- Prefer a listener alias or a DNS CNAME over a literal instance name, so
  moving SQL does not mean editing every consumer.

---

## Evidence for the ticket

- `/health` JSON showing `kind` and the attempted server.
- The `ORDERDESK_SQL_*` values as found.
- `sqlcmd` output proving the correct instance answers.
- Confirmation that SQL logged **no** failed login — which is what separates
  this from runbooks 01 and 04.
