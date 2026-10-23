# OrderDesk — a Windows Server app-support lab

A deliberately small line-of-business app, hosted the way a real one is, with
the tooling an application support engineer actually needs: a schema with an
audit trail, investigation SQL, a controlled data-fix, a health check, and
runbooks for four failures you can inject on demand.

- **App** — Flask, hosted on **IIS** via HttpPlatformHandler, in its own app
  pool, running as its own low-privilege **service account**
- **Database** — **SQL Server Express** (or Developer, for SQL Agent), with an
  audit table and trigger
- **Failures** — bad service-account password, stopped app pool, bad
  connection string, permission denied — each with a break script, a fix
  script and a runbook

> **Read first:** the PowerShell and T-SQL in this repo have **not been run**.
> They were written and reviewed on macOS, where no Windows Server VM or SQL
> Server instance was available. The Flask app and the seed arithmetic *were*
> verified by running them against an offline SQLite harness. See
> [What has and has not been verified](docs/LAB-BUILD.md#7-what-has-and-has-not-been-verified).

---

## Build it

Full instructions: **[docs/LAB-BUILD.md](docs/LAB-BUILD.md)**. The short
version, on a Windows Server 2019/2022 VM, elevated, with the repo at `C:\Lab`:

```powershell
cd C:\Lab\powershell
.\Install-LabPrereqs.ps1 -SqlSetupPath <path to SQL setup.exe>
.\New-LabServiceAccount.ps1
.\Deploy-LabApp.ps1
.\Invoke-LabHealthCheck.ps1
```

Then `http://localhost:8080/`. **Snapshot the VM before breaking anything.**

---

## What is in here

```
app/                    the Flask app
  app.py                routes: /, /orders, /discrepancies, /audit, /health, /diag
  db.py                 data access; classifies SQL failures into support categories
  config.py             connection string assembly, with password redaction
  web.config            IIS hosting via HttpPlatformHandler
  dev/                  offline SQLite smoke harness (dev only, not for the VM)

sql/
  01_schema.sql         tables, audit table, audit trigger, append-only guard
  02_seed.sql           seed data plus four planted discrepancies
  03_investigate.sql    read-only investigation, in ten numbered sections
  04_datafix_controlled.sql   backup -> BEGIN TRAN -> verify -> COMMIT/ROLLBACK
  05_sqlagent_jobs.sql  reconciliation proc + Agent jobs (Express fallback included)
  06_app_login_permissions.sql   least-privilege grants for the app account

powershell/
  lab.config.ps1        every name and path in one place; no passwords
  Install-LabPrereqs.ps1    IIS, HttpPlatformHandler, Python, ODBC, SQL, firewall
  New-LabServiceAccount.ps1 account, IIS_IUSRS, batch/service logon rights
  Deploy-LabApp.ps1         deploy, app pool, site, ACLs, run the SQL
  Invoke-LabHealthCheck.ps1 services, app pools, SQL Agent jobs, and more
  Invoke-LabBreak.ps1       inject failure 1, 2, 3, 4 or all
  Invoke-LabFix.ps1         repair each one, and verify

runbooks/
  00-index.md           decision tree: which failure is this?
  01-bad-service-account-password.md
  02-stopped-app-pool.md
  03-bad-connection-string.md
  04-permission-denied.md

docs/LAB-BUILD.md       VM build, SQL edition choice, troubleshooting, verification status
```

---

## The data model

Three app tables, one audit table, one rule:

> `app.Orders.Amount` must equal the sum of its `app.OrderLines.LineTotal`.

Nothing enforces that at write time — deliberately. `LineTotal` is a persisted
computed column, so the *line* side is always right; only the header can
drift. That is the discrepancy the investigation scripts chase.

`audit.OrderAudit` gets a row per affected order per statement, written by
`app.trg_Orders_Audit`, which handles INSERT, UPDATE and DELETE in one
definition and copes with multi-row statements via a `FULL OUTER JOIN` of
`inserted` and `deleted`. Before and after images are stored as JSON, so the
audit table never needs altering when `app.Orders` gains a column. Changed
columns are detected with the null-safe `EXISTS (SELECT i.Col EXCEPT SELECT
d.Col)` idiom, so a value moving to or from NULL still counts as a change.

Two details worth copying into real work:

- The app calls `sp_set_session_context` on connect, so the audit row records
  the **end user** as well as the shared service account. Without it, every
  change is attributed to `svc_orderdesk` and the audit trail tells you
  nothing.
- `audit.OrderAudit` carries an `INSTEAD OF UPDATE, DELETE` trigger making it
  append-only, with `ops.usp_PurgeOrderAudit` as the single sanctioned way to
  age rows out.

### The planted discrepancies

Net variance 617.00 across four orders, each mimicking a real cause:

| Order | Header | Lines | Variance | Cause |
|---|---|---|---|---|
| SO-1003 | 2190.00 | 2100.00 | +90.00 | refund hit the lines, header not recalculated |
| SO-1007 | 1557.00 | 1575.00 | −18.00 | manual header edit, mistyped |
| SO-1008 | 640.00 | 0.00 | +640.00 | cleanup script deleted the lines |
| SO-1010 | 205.00 | 300.00 | −95.00 | integration added a line, header untouched |

SO-1008 is **excluded from the automated fix on purpose**. Its lines are gone;
setting the header to zero would destroy evidence, not repair data. A fix
script that quietly "corrects" that row is worse than no fix script.

---

## The controlled data fix

`sql/04_datafix_controlled.sql` is the shape worth reusing:

1. `@DryRun = 1` **by default**, so a careless run changes nothing.
2. Pre-flight gates — candidate list exists and still matches live data, the
   audit trigger is enabled, row count and total variance are within limits,
   nothing is blocking. Any failure stops the script before it writes.
3. A timestamped backup table, created **outside** the transaction. DDL in
   SQL Server is transactional, so a backup made inside would vanish on
   `ROLLBACK` — exactly when you want it most.
4. `BEGIN TRAN`, the `UPDATE`, then six verifications **inside** the
   transaction: row count matches expectation, every approved order now
   reconciles, nothing outside the approved set moved, only `Amount` changed,
   the audit trigger wrote one row per change, and the backup really holds the
   pre-change values.
5. `COMMIT` only if all six pass; otherwise `ROLLBACK`, with `XACT_ABORT ON`
   and a `CATCH` that rolls back and re-throws.
6. A printed rollback recipe naming the backup table.

---

## The health check

`Invoke-LabHealthCheck.ps1` is read-only and safe to run mid-incident. It
covers Windows services, the app pool (state, identity, rapid-fail settings,
live worker processes), the site and its bindings, HttpPlatformHandler
registration, the app's `/health`, whether the port is even listening, SQL
connectivity, the database and its objects, whether the audit trigger is
enabled, SQL Agent jobs **or** their Scheduled Task stand-ins on Express,
recent WAS and logon-failure events, and disk space.

Two checks earn their keep:

- It **impersonates the app's SQL principal** (`EXECUTE AS LOGIN`) and runs
  the app's real query, so a lost grant is caught before users notice. A
  health check that queries as sysadmin proves nothing about the app.
- It reports the app's `identity` from `/health`, which is how you catch an
  app pool silently running as the wrong account.

Output is a table, or `-Json` for a monitor. The exit code is the number of
failures, so it drops straight into a probe:

```powershell
powershell -File Invoke-LabHealthCheck.ps1 -Quiet
if ($LASTEXITCODE -ne 0) { # alert }
```

---

## Breaking it on purpose

```powershell
.\Invoke-LabBreak.ps1 -Scenario BadServiceAccountPassword
.\Invoke-LabHealthCheck.ps1        # diagnose it yourself
# read the runbook, fix it by hand
.\Invoke-LabFix.ps1 -Scenario BadServiceAccountPassword   # backstop only
```

| Scenario | What it does | Looks like | Runbook |
|---|---|---|---|
| `BadServiceAccountPassword` | rotates the Windows password, leaves IIS holding the old one | 503 everywhere, pool will not stay started, WAS 5021 | [01](runbooks/01-bad-service-account-password.md) |
| `StoppedAppPool` | stops the pool and clears `autoStart`; `-CrashLoop` makes the worker die until rapid-fail stops it | 503 everywhere, site still "Started" | [02](runbooks/02-stopped-app-pool.md) |
| `BadConnectionString` | one-letter typo in the SQL instance name | site loads, data screens fail, SQL sees no connection | [03](runbooks/03-bad-connection-string.md) |
| `PermissionDenied` | `DENY SELECT ON app.Orders` to the app role | site loads, SQL error 229, login succeeded | [04](runbooks/04-permission-denied.md) |

Each break records the pre-break state in
`C:\LabState\orderdesk-break-state.json`, so the fix can restore it and so you
can tell afterwards what was actually changed.

The point of the pairing is classification. All four arrive as "the site is
down" or "the page is erroring". `01` and `03` are the pair most often
confused — both read as "cannot connect to SQL" — and the difference is *who*
fails: in `01` the Windows logon fails so the app never starts, in `03` the
app runs fine and cannot find the server it was told to use.
[runbooks/00-index.md](runbooks/00-index.md) has the decision tree.

---

## Running the app without a VM

For working on the app itself, there is an offline harness that needs no
Windows and no SQL Server. It is **dev only** and proves nothing about IIS or
SQL Server:

```bash
pip install flask
app/dev/run_local_smoke.sh
```

It builds a SQLite database mirroring the schema (triggers included), starts
the app, exercises every route, confirms the audit trigger fires, and checks
that a database failure surfaces as a classified HTTP 503 rather than a 500.

---

## Known limitations

- **SQL Express has no SQL Server Agent.** `05_sqlagent_jobs.sql` detects the
  edition, skips job creation, and prints a Windows Scheduled Task equivalent
  driving the same stored procedure; the health check then checks the task.
  Use Developer edition (free) for the Agent half of the lab.
- **The service account is a plain account.** A gMSA is the right answer in
  production and removes failure 1 entirely — which is why the lab does not
  use one.
- **Installer URLs drift.** Microsoft moves them; stage installers by hand if
  a download fails.
- The app has no authentication. It is a lab, bound to port 8080, and the
  `X-Lab-User` header stands in for a signed-in user.
