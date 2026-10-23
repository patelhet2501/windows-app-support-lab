# Runbook 02 — Stopped app pool

**Severity**: site-wide outage.
**Typical cause**: the pool was stopped by hand, stopped itself after repeated
worker crashes (rapid-fail protection), or came back from a reboot with
`autoStart` false.

---

## Symptom

- **HTTP 503 Service Unavailable** on every request, returned immediately.
- The *website* still shows as Started in IIS Manager — only the pool is down.
  This trips people up: a green site with a stopped pool serves nothing.
- No entry in the IIS access log for the request either, because
  `http.sys` returns the 503 before the pipeline runs.

Distinguishing it from runbook 01: here the pool stays stopped *quietly*, with
no WAS 5021. If the pool also refuses to stay started, it is either 01 (bad
identity) or a crashing worker (covered below).

## Impact

Total, until the pool runs.

---

## Triage (1 minute)

```powershell
Import-Module WebAdministration
Get-WebAppPoolState -Name OrderDeskPool
Get-Website -Name OrderDesk | Select-Object Name, State, PhysicalPath, ApplicationPool
Get-Service W3SVC, WAS | Select-Object Name, Status, StartType
```

Then just try it:

```powershell
Start-WebAppPool -Name OrderDeskPool
Start-Sleep -Seconds 3
Get-WebAppPoolState -Name OrderDeskPool
```

- **Starts and stays Started** → it was simply stopped. Find out who stopped
  it (below) and close the ticket.
- **Starts, then stops again** → the worker is crashing. Go to *Crashing
  worker*.
- **Will not start at all** → check the identity (runbook 01) and that W3SVC
  and WAS are running.

---

## Diagnosis

### 1. Is anything listening?

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

With W3SVC running, `http.sys` holds the port even when the pool is down —
which is precisely how you get a 503 rather than a connection refusal. No
listener at all means W3SVC itself is stopped or the binding is gone.

### 2. Why is it stopped? The event log says.

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'; ProviderName='Microsoft-Windows-WAS'
    StartTime=(Get-Date).AddHours(-6)
} | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

| Event | Meaning | Where to go |
|---|---|---|
| 5002 | Rapid-fail protection stopped the pool | *Crashing worker*, below |
| 5021 | Identity invalid | runbook 01 |
| 5057 | Pool disabled after start failures | *Crashing worker* |
| 5079/5080 | Pool stopped/started administratively | someone did it on purpose |
| 5186 | Worker process failed to start | *Crashing worker* |

Who stopped it, if it was deliberate:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='Microsoft-IIS-Configuration/Operational'
    StartTime=(Get-Date).AddDays(-1)
} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message -First 20 | Format-List
```

That log is off by default; enable it in Event Viewer under
*Applications and Services Logs → Microsoft → Windows → IIS-Configuration*.
Worth turning on before you need it.

### 3. Will it survive a restart?

```powershell
(Get-ItemProperty IIS:\AppPools\OrderDeskPool -Name autoStart).Value
```

`False` means it will come back stopped after every reboot — a stopped pool
that keeps "coming back" is usually this.

### 4. Rapid-fail protection settings

```powershell
(Get-Item IIS:\AppPools\OrderDeskPool).failure |
    Select-Object rapidFailProtection, rapidFailProtectionMaxCrashes,
                  rapidFailProtectionInterval, autoShutdownExe
```

Default: 5 crashes in 5 minutes stops the pool. That is a feature. Raising
the threshold hides a crash loop instead of fixing it.

---

## Crashing worker

If the pool will not stay up, the worker is dying on start. For this app that
means HttpPlatformHandler cannot launch Python, or Python exits immediately.

### 1. Read the handler's stdout log — the single most useful file

```powershell
Get-ChildItem C:\inetpub\OrderDesk\logs\httpplatform-stdout*.log |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
    Get-Content -Tail 60
```

A Python traceback here (bad import, missing module, syntax error) is the
answer. Nothing at all means the process never started — check `processPath`.

### 2. Does the interpreter named in web.config exist?

```powershell
[xml]$wc = Get-Content C:\inetpub\OrderDesk\web.config
$pp = $wc.configuration.'system.webServer'.httpPlatform.processPath
$pp; Test-Path $pp
$wc.configuration.'system.webServer'.httpPlatform.arguments
```

`False` from `Test-Path` is the crash cause. This is what
`Invoke-LabBreak.ps1 -Scenario StoppedAppPool -CrashLoop` injects.

### 3. Run the app by hand as the service account

Takes IIS out of the picture entirely:

```powershell
$cred = Get-Credential -UserName "$env:COMPUTERNAME\svc_orderdesk" -Message 'Run app'
Start-Process -FilePath C:\Python312\python.exe `
    -ArgumentList 'C:\inetpub\OrderDesk\app.py' `
    -WorkingDirectory C:\inetpub\OrderDesk `
    -Credential $cred -NoNewWindow -Wait
```

If it fails here, it was never an IIS problem.

### 4. Is the module registered?

```powershell
Get-WebGlobalModule | Where-Object Name -eq 'httpPlatformHandler'
```

Missing → IIS returns **500.21** rather than 503, and the pool is fine.
Install HttpPlatformHandler (`Install-LabPrereqs.ps1`).

### 5. Check for a port clash

```powershell
Get-WebBinding | Select-Object ItemXPath, bindingInformation
Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue
```

Two sites bound to 8080 means one of them fails to start.

---

## Fix

### Simply stopped

```powershell
Set-ItemProperty IIS:\AppPools\OrderDeskPool -Name autoStart -Value $true
Start-WebAppPool -Name OrderDeskPool
```

### Crashing worker

Repair the cause first — a pool started over a broken config just stops again.

```powershell
# e.g. restore a valid interpreter path
[xml]$wc = Get-Content C:\inetpub\OrderDesk\web.config
$wc.configuration.'system.webServer'.httpPlatform.processPath = 'C:\Python312\python.exe'
$wc.Save('C:\inetpub\OrderDesk\web.config')

Set-ItemProperty IIS:\AppPools\OrderDeskPool -Name autoStart -Value $true
Start-WebAppPool -Name OrderDeskPool
```

### Services down

```powershell
Start-Service WAS      # WAS first; W3SVC depends on it
Start-Service W3SVC
Set-Service W3SVC -StartupType Automatic
```

### Last resort

```powershell
# Re-reads applicationHost.config. Drops every pool on the box, so get
# approval on a shared server.
Restart-Service W3SVC -Force
```

---

## Verify

```powershell
Get-WebAppPoolState -Name OrderDeskPool
Start-Sleep -Seconds 10
Get-WebAppPoolState -Name OrderDeskPool        # still Started, not flapping

Get-ChildItem 'IIS:\AppPools\OrderDeskPool\WorkerProcesses'   # a w3wp exists

(Invoke-WebRequest http://localhost:8080/health -UseBasicParsing).StatusCode  # 200
```

Then confirm it survives the thing that broke it:

```powershell
Restart-WebAppPool -Name OrderDeskPool
Start-Sleep -Seconds 8
Invoke-RestMethod http://localhost:8080/health | Select-Object status, identity, uptime_seconds
```

And no new WAS events:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'; ProviderName='Microsoft-Windows-WAS'
    StartTime=(Get-Date).AddMinutes(-10)
} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id
```

---

## Rollback

Starting a pool needs no rollback. If you edited `web.config`, IIS keeps
backups of the global config under
`C:\inetpub\history` (when configuration history is on); for the app's own
`web.config`, re-run `Deploy-LabApp.ps1`, which rewrites it from source.

---

## Prevention

- Keep `autoStart = true` and `startMode = AlwaysRunning` so a reboot brings
  the pool back without the first request paying for it.
- Leave rapid-fail protection on, and alert on WAS 5002 — it means a crash
  loop was caught, which you want to know about immediately.
- Monitor the pool state itself, not only HTTP:

  ```powershell
  if ((Get-WebAppPoolState -Name OrderDeskPool).Value -ne 'Started') { <alert> }
  ```

- Turn on the IIS-Configuration operational log *before* an incident, so
  "who stopped it" is answerable afterwards.
- Keep `stdoutLogEnabled="true"`. It costs a little disk and is the only
  place a Python traceback lands under IIS.

---

## Evidence for the ticket

- `Get-WebAppPoolState` before and after.
- The WAS event that explains the stop (5002 / 5079 / 5186).
- Tail of `httpplatform-stdout*.log` if the worker was crashing.
- `autoStart` value as found.
