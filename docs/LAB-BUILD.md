# Building the lab VM

Everything in this repo is written to run on one Windows Server VM. Nothing
here was executed on a Windows machine by the author — the code was written
and reviewed on macOS, and the Flask app plus its SQL logic were verified
against the offline SQLite harness (see *What has and has not been verified*
at the end). Expect to debug a path or a version; that is part of the lab.

---

## 1. The VM

| Item | Recommended | Minimum |
|---|---|---|
| OS | Windows Server 2022 | Windows Server 2019 |
| vCPU | 4 | 2 |
| RAM | 8 GB | 4 GB |
| Disk | 80 GB | 50 GB |
| Networking | NAT plus host-only, or bridged | NAT |

Hyper-V, VMware Workstation/Fusion, VirtualBox or any cloud VM all work.
Evaluation media for Server 2022 is available from the Microsoft Evaluation
Center and runs for 180 days, which is more than enough.

**Take a snapshot once the lab is deployed and healthy.** You are about to
break it on purpose four times; a snapshot turns a bad afternoon into a
two-minute revert.

### Workgroup or domain?

A workgroup VM is enough for all four failures and is much quicker to build —
`lab.config.ps1` defaults to a local account (`.\svc_orderdesk`). Build a
domain only if you want to practise the AD side of the password failure
(expiry policy, lockout, gMSA). To go domain, set `ServiceAccount` to
`LABNET\svc_orderdesk` and run `New-LabServiceAccount.ps1 -SkipAccountCreation`.

---

## 2. Which SQL edition

This matters, and it is the one place the lab cannot have everything at once.

| | Express | Developer |
|---|---|---|
| Price | free | free |
| Database engine | yes | yes |
| **SQL Server Agent** | **no** | **yes** |
| Memory ceiling | 1.4 GB | none |
| Licensed for production | yes | no, dev/test only |

SQL Server **Express has no working SQL Server Agent**. The
`SQLAgent$SQLEXPRESS` service exists but cannot start, and the msdb job tables
are present but unusable. So:

- Want the SQL Agent jobs part of the lab? **Install Developer edition.**
- Happy with Express? `sql\05_sqlagent_jobs.sql` detects it, skips the job
  creation, and prints a Windows Scheduled Task equivalent that drives the
  same stored procedure. The health check then checks the task instead of the
  job, and says so.

Everything else in the lab is identical on both.

---

## 3. Get the files onto the VM

Put this repo at `C:\Lab`, so the paths in the runbooks match:

```powershell
# from an elevated PowerShell prompt on the VM
New-Item -ItemType Directory -Path C:\Lab -Force
# then copy the repo in: shared folder, git clone, or RDP drive redirection
```

Unblock the scripts if they came over the network, and allow them to run:

```powershell
Get-ChildItem C:\Lab -Recurse -Include *.ps1 | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

---

## 4. Build it

Four commands, in order, from `C:\Lab\powershell` in an **elevated** prompt.

### 4.1 Prerequisites

```powershell
cd C:\Lab\powershell
.\Install-LabPrereqs.ps1
```

Installs IIS and its management tools, HttpPlatformHandler, Python 3.12, the
ODBC Driver 18, and opens TCP 8080. It downloads what it needs; on an offline
VM, stage the installers in `C:\LabInstallers` first and add `-SkipDownload`.
Expected filenames are listed in the `$downloads` table at the top of the
script.

SQL is not installed unless you point at its media:

```powershell
# Express
.\Install-LabPrereqs.ps1 -SqlSetupPath C:\LabInstallers\SQLEXPR_x64_ENU\setup.exe

# Developer, if you want SQL Agent
.\Install-LabPrereqs.ps1 -SqlEdition Developer -SqlSetupPath D:\setup.exe
```

The script prompts for the `sa` password; it is passed to SQL setup and not
stored. Reboot if it asks.

### 4.2 Service account

```powershell
.\New-LabServiceAccount.ps1
```

Creates `svc_orderdesk`, adds it to `IIS_IUSRS`, and grants "log on as a batch
job" and "log on as a service" via `secedit`. You will be prompted for a
password twice — **write it down**, the deploy step asks for it again and
runbook 01 needs it.

Note the deliberate choice: the password is left able to expire, because that
is failure 1 arriving on its own. Pass `-PasswordNeverExpires` if you would
rather it did not.

### 4.3 Deploy

```powershell
.\Deploy-LabApp.ps1
```

Copies the app to `C:\inetpub\OrderDesk`, pip-installs Flask and pyodbc,
rewrites `web.config` for this machine, creates the app pool under the service
account, creates the site on port 8080, sets ACLs (read+execute on content,
modify on `logs` only), runs `sql\01`, `02`, `05` and `06`, then proves
`/health` answers.

### 4.4 Check

```powershell
.\Invoke-LabHealthCheck.ps1
```

Everything should be `Pass`, except on Express where the SQL Agent rows are
`Skip`, and `order totals reconcile` which is a deliberate `Warn` — the seed
plants four discrepancies for you to investigate.

Then open `http://localhost:8080/` in the VM's browser.

**Snapshot the VM now.**

---

## 5. Walk through the lab

### 5.1 The data discrepancy

```powershell
sqlcmd -S localhost\SQLEXPRESS -d AppSupportLab -E -i C:\Lab\sql\03_investigate.sql -o C:\Lab\investigate-output.txt
notepad C:\Lab\investigate-output.txt
```

Better still, open `03_investigate.sql` in SSMS and run it section by section.
It is written to be read in order: headline numbers, then the offending rows
classified by shape, then blast radius, then who did it from the audit trail,
then the false positives to rule out, then the candidate fix list.

Four orders are planted, with a net variance of 617.00:

| Order | Header | Lines | Variance | Cause mimicked |
|---|---|---|---|---|
| SO-1003 | 2190.00 | 2100.00 | +90.00 | refund applied to lines, header not recalculated |
| SO-1007 | 1557.00 | 1575.00 | −18.00 | fat-fingered manual header edit in SSMS |
| SO-1008 | 640.00 | 0.00 | +640.00 | cleanup script deleted the lines |
| SO-1010 | 205.00 | 300.00 | −95.00 | integration added a line, header untouched |

Then the fix, which defaults to a dry run:

```powershell
# dry run first: verifies everything, then rolls back
sqlcmd -S localhost\SQLEXPRESS -d AppSupportLab -E -i C:\Lab\sql\04_datafix_controlled.sql
```

Read the output. Then set `@DryRun = 0` in the script and run it again to
commit. Note that SO-1008 is *excluded* from the fix on purpose: its lines are
missing, and rewriting the header to zero would destroy the evidence rather
than fix the data. Three orders get corrected; one stays for a human.

### 5.2 The four failures

One at a time, and diagnose before you read the answer:

```powershell
.\Invoke-LabBreak.ps1 -Scenario BadServiceAccountPassword
.\Invoke-LabHealthCheck.ps1          # work out what happened
#   ... now read runbooks\01-bad-service-account-password.md and fix it by hand
.\Invoke-LabHealthCheck.ps1          # confirm you are back to clean
```

Repeat for `StoppedAppPool` (add `-CrashLoop` for the more realistic variant,
where rapid-fail protection stops the pool for you), `BadConnectionString`
and `PermissionDenied`.

`Invoke-LabFix.ps1 -Scenario <name>` repairs each one if you get stuck, and
`-Scenario All` resets everything. Use it as a backstop, not as the exercise.

The honest test of whether the lab worked: break one at random, and see
whether you can name which of the four it is from `/health` and the event log
alone, before touching anything.

---

## 6. Troubleshooting the build

| Symptom | Cause | Fix |
|---|---|---|
| HTTP 500.19 | `web.config` unreadable or malformed | check XML, and that the pool identity can read the file |
| HTTP 500.21 | HttpPlatformHandler not installed | `Install-LabPrereqs.ps1` |
| HTTP 502.5 | the Python process died at startup | read `C:\inetpub\OrderDesk\logs\httpplatform-stdout*.log` |
| HTTP 503 right after deploy | pool could not start | runbook 02; check the identity password |
| `pyodbc` import error | ODBC driver or VC++ runtime missing | reinstall msodbcsql18 |
| `Invoke-Sqlcmd` not found | SqlServer module missing | the scripts fall back to `sqlcmd.exe`; or `Install-Module SqlServer` |
| SQL login fails from the app only | pool identity is not the SQL principal you granted | `/diag` shows the identity; compare with `sql\06` |
| Downloads 404 | Microsoft moved a URL | fetch by hand into `C:\LabInstallers` under the expected name |

Logs worth knowing, in the order you will want them:

```
C:\inetpub\OrderDesk\logs\httpplatform-stdout*.log   Python stdout and tracebacks
C:\inetpub\OrderDesk\logs\orderdesk.log              the app's own log
C:\inetpub\logs\LogFiles\W3SVC*\                     IIS access logs
Event Viewer > Windows Logs > System                 WAS app-pool events
Event Viewer > Windows Logs > Security               4625 / 4740 logon failures
C:\Program Files\Microsoft SQL Server\MSSQL*.SQLEXPRESS\MSSQL\LOG\ERRORLOG
```

---

## 7. What has and has not been verified

Being straight about this, because it changes how you should read the code.

**Verified by running it:**

- The Flask app, end to end, against the offline SQLite harness
  (`app/dev/run_local_smoke.sh`): all ten routes, the status-change POST, the
  audit trigger firing and recording the acting user, rejection of an invalid
  status, and the degraded path returning HTTP 503 with a classified failure
  kind rather than a bare 500.
- The seed arithmetic: the baseline reconciles exactly, and the four planted
  discrepancies produce variances of +90.00, −18.00, +640.00 and −95.00 for a
  net of 617.00 — confirmed both by independent calculation and by the
  running app's `/api/discrepancies`.
- `app/web.config` is well-formed XML.
- All Python parses and imports cleanly.

**Not verified, because it needs a Windows Server VM:**

- Every PowerShell script. They were written against the documented cmdlet
  behaviour and reviewed, but never executed. No PowerShell runtime was
  available.
- All T-SQL. `sql/01`–`06` were never run against a SQL Server instance; the
  SQLite harness mirrors the schema and the audit-trigger *shape*, which is
  not the same as having run the T-SQL. The trigger's `FOR JSON PATH`,
  `SESSION_CONTEXT`, `CONCAT_WS` and `FULL OUTER JOIN` of `inserted`/`deleted`
  are all standard but unexercised here.
- The IIS hosting path: HttpPlatformHandler, the app pool identity, the ACLs,
  and the four injected failures actually producing the event-log entries the
  runbooks cite.
- Installer download URLs, which Microsoft changes.

So: run `01_schema.sql` first and read its output before anything else, and
expect to fix a typo or two on the first pass. The scripts are built to fail
loudly and idempotently — re-running them is safe and is the intended way to
work through any breakage.
