# OrderDesk runbooks — index

Four failures, and how to tell them apart. All four look the same to a user
("the site is down" or "the page errors"), so the first job is always
classification, not repair.

Run this first, whatever the symptom:

```powershell
cd C:\Lab\powershell
.\Invoke-LabHealthCheck.ps1
```

## Decision tree

```
Site returns HTTP 503 immediately, no page at all
├── App pool state is Stopped
│   ├── System event log has WAS 5021 ("identity is invalid")
│   │        -> 01  bad service-account password
│   ├── System event log has WAS 5002 (rapid-fail protection)
│   │        -> 02  stopped app pool (crash loop; find why the worker dies)
│   └── no relevant event, pool simply stopped / autoStart false
│            -> 02  stopped app pool
└── App pool state is Started but nothing listens on the port
         -> 02  stopped app pool (check W3SVC and the site binding)

Site serves pages, but data screens show "Database unavailable"
├── /health reports kind = "unreachable"
│        -> 03  bad connection string
├── /health reports kind = "login_failed"  (SQL error 18456 / 4060)
│        -> 01  bad service-account password  (or the SQL login is gone: 04)
├── /health reports kind = "permission_denied"  (SQL error 229)
│        -> 04  permission denied
└── /health reports kind = "missing_object"  (SQL error 208)
         -> 03  bad connection string (connected to the wrong database)

Site and database both fine, but the numbers are wrong
         -> sql\03_investigate.sql, then sql\04_datafix_controlled.sql
```

## The fastest single distinguishing signal

| Question | Answer | Failure |
|---|---|---|
| Does the app pool stay started? | No, and WAS logs 5021 | 01 password |
| Does the app pool stay started? | No, and nothing else is wrong with it | 02 app pool |
| Did SQL ever see a connection attempt? | No | 03 connection string |
| Did SQL see the login succeed and then refuse a statement? | Yes, error 229 | 04 permission |

`01` and `03` are the pair most often confused: both produce "cannot connect
to SQL". The difference is *who* is failing. In `01` the Windows logon fails,
so the worker process never starts and the app never runs. In `03` the app
runs happily and cannot find the server it was told to use.

## Runbooks

| # | Failure | Runbook |
|---|---|---|
| 01 | Bad service-account password | [01-bad-service-account-password.md](01-bad-service-account-password.md) |
| 02 | Stopped app pool | [02-stopped-app-pool.md](02-stopped-app-pool.md) |
| 03 | Bad connection string | [03-bad-connection-string.md](03-bad-connection-string.md) |
| 04 | Permission denied | [04-permission-denied.md](04-permission-denied.md) |

## Reference

| What | Where |
|---|---|
| Site | `http://localhost:8080/` |
| Health probe | `http://localhost:8080/health` |
| Diagnostics | `http://localhost:8080/diag` |
| App files | `C:\inetpub\OrderDesk` |
| App + stdout logs | `C:\inetpub\OrderDesk\logs` |
| IIS logs | `C:\inetpub\logs\LogFiles\W3SVC*` |
| App pool | `OrderDeskPool` |
| Service account | `.\svc_orderdesk` |
| SQL instance | `localhost\SQLEXPRESS`, database `AppSupportLab` |
| Break/fix state | `C:\LabState\orderdesk-break-state.json` |

## Practising

```powershell
.\Invoke-LabBreak.ps1 -Scenario BadServiceAccountPassword   # or another
.\Invoke-LabHealthCheck.ps1        # diagnose it yourself first
# read the runbook, fix by hand
.\Invoke-LabFix.ps1 -Scenario BadServiceAccountPassword     # backstop only
```

Work the runbook before reaching for `Invoke-LabFix.ps1`. The script is there
to reset the lab, not to do the exercise for you.
