# Runbook 01 — Bad service-account password

**Severity**: site-wide outage. Nothing is served.
**Typical cause**: the service-account password expired or was rotated in
Windows/AD, and the IIS app pool was not updated to match.

---

## Symptom

- Every request returns **HTTP 503 Service Unavailable**, instantly.
- No page renders, not even the landing page — so this is *not* a database
  problem, however much "503" looks like one.
- The app pool is **Stopped**, and starting it does not keep it started.
- Nothing is written to `C:\inetpub\OrderDesk\logs\orderdesk.log`, because the
  Python process never ran.

The absence of app logs is the key early signal: the application never
started, so the fault is below it.

## Impact

Total. IIS cannot create a worker process, so no request reaches the app.

---

## Triage (2 minutes)

```powershell
Import-Module WebAdministration
Get-WebAppPoolState -Name OrderDeskPool
Get-Service W3SVC, WAS | Select-Object Name, Status
```

Expect pool `Stopped` while both services are `Running`. Services up + pool
down + no app log is this failure's fingerprint.

```powershell
Start-WebAppPool -Name OrderDeskPool
Start-Sleep -Seconds 3
Get-WebAppPoolState -Name OrderDeskPool      # back to Stopped -> confirmed
```

A pool that will not *stay* started is a pool that cannot log on.

---

## Diagnosis

### 1. The event log names this failure outright

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS'
    StartTime = (Get-Date).AddHours(-2)
} | Select-Object TimeCreated, Id, Message -First 10 | Format-List
```

Look for:

| Event | Meaning |
|---|---|
| **5021** | The identity of app pool X is invalid — **this failure** |
| 5057  | App pool has been disabled after repeated start failures |
| 5059  | App pool disabled; AppPoolAutoStart cleared |
| 5002  | Rapid-fail protection stopped the pool |

Event 5021 says the credentials IIS holds are not accepted by Windows.

### 2. Confirm at the Windows layer

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='Security'; Id=4625,4740; StartTime=(Get-Date).AddHours(-2)
} | Where-Object Message -like '*svc_orderdesk*' |
  Select-Object TimeCreated, Id -First 5
```

- **4625** — failed logon (bad password). Status `0xC000006A` is specifically
  "wrong password"; `0xC0000071` is "password expired".
- **4740** — the account was locked out, usually by repeated retries.

### 3. Check the account itself

```powershell
Get-LocalUser -Name svc_orderdesk |
    Select-Object Name, Enabled, PasswordExpires, PasswordLastSet, UserMayChangePassword
```

A `PasswordExpires` in the past, or `Enabled = False`, is the root cause.

For a domain account:

```powershell
Get-ADUser svc_orderdesk -Properties PasswordExpired, PasswordLastSet, LockedOut, Enabled |
    Select-Object Name, Enabled, LockedOut, PasswordExpired, PasswordLastSet
```

### 4. Check what IIS thinks the identity is

```powershell
$p = Get-Item IIS:\AppPools\OrderDeskPool
$p.processModel | Select-Object identityType, userName, loadUserProfile
```

IIS stores the password encrypted in `applicationHost.config` and will not
show it. You cannot compare the two passwords — which is exactly why this
failure happens, and why the fix sets both sides at once.

### 5. Prove the credentials by hand

The cleanest confirmation: try the logon yourself.

```powershell
$cred = Get-Credential -UserName "$env:COMPUTERNAME\svc_orderdesk" -Message 'Test'
Start-Process -FilePath cmd.exe -ArgumentList '/c','whoami' -Credential $cred -NoNewWindow
```

A `The user name or password is incorrect` here settles it. (This needs
"Log on as a batch job", which `New-LabServiceAccount.ps1` granted.)

---

## Root cause

Two stores must hold the same secret:

1. Windows (or AD) — the account's actual password.
2. `applicationHost.config` — the copy IIS presents when starting a worker.

Rotating one without the other breaks the pool. IIS does not retry its way
out of this, and after repeated failures it disables the pool so it stops
hammering the account into lockout.

---

## Fix

### 1. Unlock the account if it is locked

```powershell
# local
Enable-LocalUser -Name svc_orderdesk
# domain
Unlock-ADAccount -Identity svc_orderdesk
```

### 2. Set the password, in both places, to the same value

```powershell
$cred = Get-Credential -UserName "$env:COMPUTERNAME\svc_orderdesk" `
                       -Message 'New service account password'

# Windows side
Set-LocalUser -Name svc_orderdesk -Password $cred.Password

# IIS side — identityType 3 = SpecificUser
Set-ItemProperty -Path IIS:\AppPools\OrderDeskPool -Name processModel -Value @{
    identityType = 3
    userName     = $cred.UserName
    password     = $cred.GetNetworkCredential().Password
}
```

On a domain, reset in AD instead of `Set-LocalUser`, then run only the IIS
half — and remember every *other* consumer of that account (scheduled tasks,
other app pools, Windows services) needs the same update.

### 3. Re-arm and start the pool

Repeated failures may have cleared `autoStart`:

```powershell
Set-ItemProperty IIS:\AppPools\OrderDeskPool -Name autoStart -Value $true
Start-WebAppPool -Name OrderDeskPool
```

### 4. Stop it recurring

```powershell
# Lab convenience; in production prefer a managed service account instead.
Set-LocalUser -Name svc_orderdesk -PasswordNeverExpires $true
```

The better answer is a **group Managed Service Account (gMSA)**, where
Windows rotates the password and IIS follows automatically. See *Prevention*.

---

## Verify

```powershell
Get-WebAppPoolState -Name OrderDeskPool            # Started
Start-Sleep -Seconds 5
Get-WebAppPoolState -Name OrderDeskPool            # still Started

Invoke-RestMethod http://localhost:8080/health | ConvertTo-Json -Depth 4
```

`status` should be `healthy`, and `identity` should be `svc_orderdesk` — proof
the worker is running as the intended account, not as something else.

A worker process must now exist:

```powershell
Get-ChildItem 'IIS:\AppPools\OrderDeskPool\WorkerProcesses'
```

And no new 5021:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName='System'; ProviderName='Microsoft-Windows-WAS'
    StartTime=(Get-Date).AddMinutes(-5)
} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id
```

Then the full check:

```powershell
.\Invoke-LabHealthCheck.ps1
```

---

## Rollback

Nothing destructive was done; the fix only set a password. If the new password
breaks another consumer of the account, set it back to the previous value in
both places — or, if that value is lost, set a third password everywhere and
update each consumer.

---

## Prevention

- **gMSA** for app pool identities: no password to rotate or forget.
- If a plain account must be used, record every consumer of it and make
  rotation a checklist that updates all of them in one change.
- Alert on WAS 5021 and 5057; they are unambiguous and arrive before users do.
- Monitor password expiry:

  ```powershell
  Get-LocalUser svc_orderdesk | Select-Object Name, PasswordExpires
  ```

- Keep rapid-fail protection on. It converts a lockout-inducing retry storm
  into one clean, visible stop.

---

## Evidence for the ticket

- WAS 5021 entry, with timestamp.
- Security 4625/4740 entries for the account.
- `Get-LocalUser` output showing expiry or disabled state.
- `/health` output before and after, showing `identity`.
