# Runbook 04 — Permission denied

**Severity**: partial outage, and often a *selective* one — some screens work
and others do not, which is the tell.
**Typical cause**: a grant lost in a database refresh, a `DENY` added by a
hardening change, a role membership dropped, or a restored database whose
users are orphaned from their logins.

---

## Symptom

- The site loads and SQL is reachable, so runbooks 02 and 03 are out.
- `/health` returns **HTTP 503** with `kind: permission_denied`.
- The message names the object:
  *"The SELECT permission was denied on the object 'Orders', database
  'AppSupportLab', schema 'app'."* — **SQL error 229**.
- The login itself **succeeded**. SQL accepted who you are and refused what
  you asked. That is the difference from runbook 01.

Error numbers worth knowing:

| Error | Meaning |
|---|---|
| **229** | permission denied on an object — this failure |
| 230 | permission denied on a *column* |
| 297 | the user does not have permission to perform this action |
| 262 | permission denied in database (e.g. CREATE) |
| 916 | the principal cannot access the database under the current context |
| 18456 | login failed — not this runbook; see 01 |
| 15517 | cannot execute as the database principal (broken owner) |

## Impact

Whatever the missing right covers. A missing `SELECT` on one table breaks
only the screens that read it, which is why this often arrives as "the orders
page is broken but the rest is fine".

---

## Triage (2 minutes)

```powershell
try { Invoke-RestMethod http://localhost:8080/health }
catch { $_.ErrorDetails.Message }
```

`kind: permission_denied` with `native_error: 229` sends you straight here.

Which identity is being refused:

```powershell
Invoke-RestMethod http://localhost:8080/diag | Select-Object identity, connection_string
```

With `Trusted_Connection=yes`, the SQL principal *is* the app pool identity.
Change the pool identity and you change the SQL principal — a common
accidental cause of this failure.

---

## Diagnosis

### 1. Reproduce as the app, not as yourself

Running the query as a sysadmin proves nothing. Impersonate:

```sql
USE AppSupportLab;
GO
EXECUTE AS LOGIN = 'WIN-LAB01\svc_orderdesk';   -- the app pool identity
SELECT SUSER_SNAME() AS LoginName, USER_NAME() AS DbUser;
SELECT TOP 1 * FROM app.Orders;                 -- expect 229 here
REVERT;
```

If `EXECUTE AS` itself fails with 15517, the database owner is broken:

```sql
SELECT SUSER_SNAME(owner_sid) AS DbOwner FROM sys.databases WHERE name = 'AppSupportLab';
-- repair with:  ALTER AUTHORIZATION ON DATABASE::AppSupportLab TO sa;
```

### 2. Ask SQL what this principal may do

```sql
USE AppSupportLab;
GO
EXECUTE AS LOGIN = 'WIN-LAB01\svc_orderdesk';

SELECT  entity_name, permission_name, subentity_name
FROM    sys.fn_my_permissions('app.Orders', 'OBJECT')
ORDER BY permission_name;

SELECT * FROM sys.fn_my_permissions(NULL, 'DATABASE') ORDER BY permission_name;
REVERT;
```

`SELECT` absent from the first result set is the finding. `sys.fn_my_permissions`
computes the *effective* right, so it already accounts for DENY and role
nesting — which is why it beats reading grants by eye.

### 3. Find the DENY

**DENY always beats GRANT**, at any level. A DENY on the object defeats a
GRANT on the schema, so look for both:

```sql
SELECT  dp.name                                   AS Principal,
        dp.type_desc,
        p.class_desc,
        p.permission_name,
        p.state_desc,                              -- GRANT | DENY | REVOKE
        COALESCE(SCHEMA_NAME(p.major_id), OBJECT_SCHEMA_NAME(p.major_id)) AS SchemaName,
        OBJECT_NAME(p.major_id)                   AS ObjectName
FROM    sys.database_permissions AS p
JOIN    sys.database_principals  AS dp ON dp.principal_id = p.grantee_principal_id
WHERE   dp.name IN ('OrderDeskApp', 'WIN-LAB01\svc_orderdesk')
ORDER BY p.state_desc DESC, p.permission_name;
```

Any row with `state_desc = 'DENY'` is the cause.

### 4. Check role membership

A grant can be intact while the account is no longer in the role that holds it:

```sql
SELECT  r.name AS RoleName, m.name AS MemberName
FROM    sys.database_role_members AS rm
JOIN    sys.database_principals   AS r ON r.principal_id = rm.role_principal_id
JOIN    sys.database_principals   AS m ON m.principal_id = rm.member_principal_id
WHERE   r.name = 'OrderDeskApp';
```

### 5. Does the user exist, and is it mapped?

```sql
SELECT  dp.name AS DbUser, dp.type_desc, dp.sid,
        sp.name AS LoginName,
        CASE WHEN sp.sid IS NULL THEN 'ORPHANED' ELSE 'mapped' END AS Mapping
FROM    sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE   dp.name = 'WIN-LAB01\svc_orderdesk';
```

`ORPHANED` is the classic aftermath of restoring a database onto another
server: the user exists in the database but points at a SID with no login.

### 6. Rule out the database-level block

```sql
SELECT  name, state_desc, user_access_desc, is_read_only
FROM    sys.databases WHERE name = 'AppSupportLab';
```

`is_read_only = 1` or `SINGLE_USER` produces permission-shaped errors on
writes that have nothing to do with grants.

### 7. Confirm from the Windows side that the login *worked*

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-1)} `
    -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -like 'MSSQL*' } |
  Select-Object TimeCreated, Id, Message -First 10 | Format-List
```

No 18456 here, plus a 229 in the app, confirms the split: authentication fine,
authorization not.

---

## Root cause

Four things must all hold for the app to read a table:

1. a **login** exists at server level for the app-pool identity;
2. a **user** in `AppSupportLab` is mapped to that login;
3. that user holds — directly or through a role — the needed permission;
4. **no DENY** applies at object, schema or database-role level.

In the lab injection, (1), (2) and (3) are intact and (4) is violated:
`DENY SELECT ON OBJECT::app.Orders TO OrderDeskApp`.

---

## Fix

Pick by cause; do not scatter grants hoping one lands.

### A DENY is present

```sql
USE AppSupportLab;
REVOKE SELECT ON OBJECT::app.Orders FROM OrderDeskApp;
```

`REVOKE` removes the DENY entry and lets the broader schema GRANT apply again.
Note that `REVOKE` is also how you remove a GRANT — it means "delete this
permission entry", not "deny".

### The grant is genuinely missing

```sql
USE AppSupportLab;
GRANT SELECT, INSERT, UPDATE ON SCHEMA::app   TO OrderDeskApp;
GRANT SELECT                  ON SCHEMA::audit TO OrderDeskApp;
GRANT SELECT                  ON SCHEMA::ops   TO OrderDeskApp;
```

Grant at **schema** level, not table by table: a new table then works without
another permission change.

### Role membership lost

```sql
ALTER ROLE OrderDeskApp ADD MEMBER [WIN-LAB01\svc_orderdesk];
```

### User orphaned after a restore

```sql
ALTER USER [WIN-LAB01\svc_orderdesk] WITH LOGIN = [WIN-LAB01\svc_orderdesk];
```

### Login or user missing entirely

Re-run the lab's own script, which is idempotent:

```powershell
sqlcmd -S localhost\SQLEXPRESS -E -b `
    -v LabServiceAccount="$env:COMPUTERNAME\svc_orderdesk" `
    -i C:\Lab\sql\06_app_login_permissions.sql
```

### Resist the shortcut

Do **not** fix this with `ALTER SERVER ROLE sysadmin ADD MEMBER` or
`db_owner`. It ends the ticket and creates a worse one, and it makes this
whole class of failure undiagnosable next time.

---

## Verify

Impersonate again — the only verification that means anything:

```sql
USE AppSupportLab;
EXECUTE AS LOGIN = 'WIN-LAB01\svc_orderdesk';
SELECT COUNT(*) AS Orders FROM app.Orders;              -- succeeds
SELECT COUNT(*) AS AuditRows FROM audit.OrderAudit;     -- succeeds
REVERT;
```

Confirm the deliberate restrictions still hold — an over-broad fix shows up here:

```sql
EXECUTE AS LOGIN = 'WIN-LAB01\svc_orderdesk';
BEGIN TRY
    DELETE FROM app.Orders WHERE 1 = 0;        -- must FAIL (229); the app never deletes
    SELECT 'PROBLEM: delete was allowed' AS Result;
END TRY
BEGIN CATCH
    SELECT 'correct: delete denied' AS Result, ERROR_NUMBER() AS ErrorNumber;
END CATCH
REVERT;
```

Then the app:

```powershell
Restart-WebAppPool -Name OrderDeskPool
Start-Sleep -Seconds 5
Invoke-RestMethod http://localhost:8080/health | ConvertTo-Json -Depth 4
(Invoke-RestMethod http://localhost:8080/api/orders).Count
.\Invoke-LabHealthCheck.ps1
```

`Invoke-LabHealthCheck.ps1` runs the impersonated read itself, so a pass there
is a real check and not just a 200 from a cached page.

---

## Rollback

Permission changes are small and scriptable. To undo the fix:

```sql
DENY SELECT ON OBJECT::app.Orders TO OrderDeskApp;   -- restores the broken state
```

Before any permission change in a real system, capture the current state so
rollback is mechanical:

```sql
SELECT 'GRANT/DENY script' AS Note, dp.name, p.state_desc, p.permission_name,
       OBJECT_NAME(p.major_id) AS ObjectName
FROM   sys.database_permissions p
JOIN   sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
WHERE  dp.name = 'OrderDeskApp';
```

---

## Prevention

- Grant to a **role**, never to the account. Then an account change is one
  `ALTER ROLE`, and the permission set is reviewable in one place.
- Grant at **schema** level so new objects inherit access.
- Keep `sql\06_app_login_permissions.sql` idempotent and in source control; it
  is both the documentation and the repair.
- Have the health check impersonate the app principal and run a real query, as
  this lab's does. It catches a lost grant before users do.
- After any database restore, run the orphaned-user check as a matter of
  course.
- Review DENY entries specifically. They are rare, they outrank everything,
  and they are easy to add during hardening and forget.

---

## Evidence for the ticket

- The app's error with SQL error number 229 and the object named.
- `sys.fn_my_permissions` output under impersonation, before and after.
- The `sys.database_permissions` row showing the DENY (or missing GRANT).
- Confirmation that SQL logged no 18456 — authentication was never the issue.
