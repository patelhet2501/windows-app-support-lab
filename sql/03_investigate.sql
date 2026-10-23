/*===========================================================================
  03_investigate.sql   AppSupportLab - investigating data discrepancies

  READ-ONLY. Nothing here changes data. Run the sections in order, or run
  one section at a time in SSMS - each is self-contained and labelled.

  The question being answered: "Finance says some order totals are wrong.
  Which ones, by how much, since when, and who did it?"

  Section 1  Is there a problem at all, and how big?
  Section 2  Which orders, and classify each by shape of the discrepancy
  Section 3  Blast radius: by customer, status, age
  Section 4  Who changed what - the audit trail
  Section 5  Rule out the false positives
  Section 6  Corroborate: header moved without the lines moving
  Section 7  Other integrity checks (orphans, duplicates, impossible values)
  Section 8  Single-order timeline, for the ticket
  Section 9  Build the candidate fix list that 04 consumes
  Section 10 Did the nightly reconciliation job run and report this?
===========================================================================*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
USE AppSupportLab;
GO

/*---------------------------------------------------------------------------
  Section 0 - where am I, and as whom? Always capture this in the ticket.
---------------------------------------------------------------------------*/
SELECT  @@SERVERNAME                        AS ServerName,
        DB_NAME()                           AS DatabaseName,
        SUSER_SNAME()                        AS LoginName,
        USER_NAME()                          AS DbUser,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('ProductVersion')) AS Version,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))        AS Edition,
        SYSUTCDATETIME()                     AS NowUtc;
GO

/*---------------------------------------------------------------------------
  Section 1 - headline numbers.
  Run this first and paste the result into the ticket. If VarianceCount is 0
  the complaint is about something else and the rest of this script is noise.
---------------------------------------------------------------------------*/
PRINT '--- Section 1: headline ---';

SELECT  COUNT(*)                                             AS OrdersTotal,
        SUM(CASE WHEN Variance <> 0 THEN 1 ELSE 0 END)       AS VarianceCount,
        SUM(CASE WHEN Variance <> 0 THEN ABS(Variance) END)  AS AbsVarianceTotal,
        SUM(Variance)                                        AS NetVariance,
        MIN(CASE WHEN Variance <> 0 THEN LastModifiedAt END) AS EarliestTouched,
        MAX(CASE WHEN Variance <> 0 THEN LastModifiedAt END) AS LatestTouched
FROM    app.vw_OrderVariance;
GO

/*---------------------------------------------------------------------------
  Section 2 - the offending rows, classified.
  The classification matters because each shape has a different fix:
    MISSING_LINES  - lines are gone; do NOT silently zero the header
    HEADER_HIGH    - header above lines; header is the likely culprit
    HEADER_LOW     - header below lines; a line was probably added later
---------------------------------------------------------------------------*/
PRINT '--- Section 2: variance detail ---';

SELECT  v.OrderId,
        v.OrderNumber,
        c.Name              AS CustomerName,
        v.Status,
        v.HeaderAmount,
        v.LineTotal,
        v.Variance,
        v.LineCount,
        CASE WHEN v.LineCount = 0 AND v.HeaderAmount <> 0 THEN 'MISSING_LINES'
             WHEN v.Variance > 0                          THEN 'HEADER_HIGH'
             ELSE                                              'HEADER_LOW'
        END                 AS Shape,
        v.LastModifiedBy,
        v.LastModifiedAt,
        DATEDIFF(DAY, v.LastModifiedAt, SYSUTCDATETIME()) AS DaysSinceTouched
FROM    app.vw_OrderVariance AS v
JOIN    app.Customers        AS c ON c.CustomerId = v.CustomerId
WHERE   v.Variance <> 0
ORDER BY ABS(v.Variance) DESC;
GO

/*---------------------------------------------------------------------------
  Section 3 - blast radius. Is this one customer, one status, one day, one
  integration? A discrepancy concentrated in one dimension names its cause.
---------------------------------------------------------------------------*/
PRINT '--- Section 3a: by customer ---';
SELECT  c.CustomerId, c.Name, c.Region,
        COUNT(*)            AS AffectedOrders,
        SUM(v.Variance)     AS NetVariance
FROM    app.vw_OrderVariance AS v
JOIN    app.Customers        AS c ON c.CustomerId = v.CustomerId
WHERE   v.Variance <> 0
GROUP BY c.CustomerId, c.Name, c.Region
ORDER BY ABS(SUM(v.Variance)) DESC;

PRINT '--- Section 3b: by status (shipped variances are the expensive ones) ---';
SELECT  v.Status, COUNT(*) AS AffectedOrders, SUM(v.Variance) AS NetVariance
FROM    app.vw_OrderVariance AS v
WHERE   v.Variance <> 0
GROUP BY v.Status
ORDER BY ABS(SUM(v.Variance)) DESC;

PRINT '--- Section 3c: by last-modified actor ---';
SELECT  v.LastModifiedBy, COUNT(*) AS AffectedOrders, SUM(v.Variance) AS NetVariance
FROM    app.vw_OrderVariance AS v
WHERE   v.Variance <> 0
GROUP BY v.LastModifiedBy
ORDER BY COUNT(*) DESC;

PRINT '--- Section 3d: by order date, to see whether it is still happening ---';
SELECT  o.OrderDate,
        COUNT(*)                                        AS OrdersOnDate,
        SUM(CASE WHEN v.Variance <> 0 THEN 1 ELSE 0 END) AS WithVariance,
        SUM(v.Variance)                                 AS NetVariance
FROM    app.Orders           AS o
JOIN    app.vw_OrderVariance AS v ON v.OrderId = o.OrderId
GROUP BY o.OrderDate
ORDER BY o.OrderDate;
GO

/*---------------------------------------------------------------------------
  Section 4 - who did it. The audit trigger stores before/after images as
  JSON, so the Amount history of a bad order is recoverable exactly.
---------------------------------------------------------------------------*/
PRINT '--- Section 4a: audit trail for every order with a variance ---';

SELECT  a.AuditId,
        o.OrderNumber,
        a.Action,
        a.ChangedColumns,
        CONVERT(DECIMAL(12,2), JSON_VALUE(a.OldValues, '$.Amount')) AS AmountBefore,
        CONVERT(DECIMAL(12,2), JSON_VALUE(a.NewValues, '$.Amount')) AS AmountAfter,
        JSON_VALUE(a.OldValues, '$.Status')                         AS StatusBefore,
        JSON_VALUE(a.NewValues, '$.Status')                         AS StatusAfter,
        a.ChangedBy,
        a.AppUser,
        a.HostName,
        a.ProgramName,
        a.ChangedAt
FROM    audit.OrderAudit AS a
JOIN    app.Orders       AS o ON o.OrderId = a.OrderId
WHERE   EXISTS (SELECT 1 FROM app.vw_OrderVariance v
                WHERE v.OrderId = a.OrderId AND v.Variance <> 0)
ORDER BY o.OrderNumber, a.AuditId;

PRINT '--- Section 4b: every Amount change ever made, newest first ---';
SELECT  o.OrderNumber,
        a.ChangedAt,
        CONVERT(DECIMAL(12,2), JSON_VALUE(a.OldValues, '$.Amount')) AS AmountBefore,
        CONVERT(DECIMAL(12,2), JSON_VALUE(a.NewValues, '$.Amount')) AS AmountAfter,
        CONVERT(DECIMAL(12,2), JSON_VALUE(a.NewValues, '$.Amount'))
          - CONVERT(DECIMAL(12,2), JSON_VALUE(a.OldValues, '$.Amount'))  AS Delta,
        a.ChangedBy, a.AppUser, a.ProgramName
FROM    audit.OrderAudit AS a
JOIN    app.Orders       AS o ON o.OrderId = a.OrderId
WHERE   a.Action = 'UPDATE'
  AND   a.ChangedColumns LIKE '%Amount%'
ORDER BY a.ChangedAt DESC;

PRINT '--- Section 4c: actors ranked by how much money they moved ---';
SELECT  COALESCE(a.AppUser, a.ChangedBy) AS Actor,
        a.ProgramName,
        COUNT(*)                         AS AmountChanges,
        SUM(CONVERT(DECIMAL(12,2), JSON_VALUE(a.NewValues, '$.Amount'))
          - CONVERT(DECIMAL(12,2), JSON_VALUE(a.OldValues, '$.Amount'))) AS NetMoved
FROM    audit.OrderAudit AS a
WHERE   a.Action = 'UPDATE' AND a.ChangedColumns LIKE '%Amount%'
GROUP BY COALESCE(a.AppUser, a.ChangedBy), a.ProgramName
ORDER BY ABS(SUM(CONVERT(DECIMAL(12,2), JSON_VALUE(a.NewValues, '$.Amount'))
               - CONVERT(DECIMAL(12,2), JSON_VALUE(a.OldValues, '$.Amount')))) DESC;
GO

/*---------------------------------------------------------------------------
  Section 5 - rule out the false positives before proposing any fix.
  A cancelled order with no lines and a zero header is correct, not broken.
  An order written seconds ago may simply be mid-insert from the app.
---------------------------------------------------------------------------*/
PRINT '--- Section 5a: legitimately empty orders (expect these to be fine) ---';
SELECT  v.OrderNumber, v.Status, v.HeaderAmount, v.LineCount,
        CASE WHEN v.Status = N'Cancelled' AND v.HeaderAmount = 0 AND v.LineCount = 0
             THEN 'OK - cancelled and empty'
             ELSE 'INVESTIGATE' END AS Verdict
FROM    app.vw_OrderVariance AS v
WHERE   v.LineCount = 0;

PRINT '--- Section 5b: too fresh to judge (written in the last 2 minutes) ---';
SELECT  v.OrderNumber, v.HeaderAmount, v.LineTotal, v.Variance, v.LastModifiedAt
FROM    app.vw_OrderVariance AS v
WHERE   v.Variance <> 0
  AND   v.LastModifiedAt > DATEADD(MINUTE, -2, SYSUTCDATETIME());

PRINT '--- Section 5c: anything blocked or open right now that would explain it? ---';
SELECT  r.session_id, r.blocking_session_id, r.status, r.wait_type, r.wait_time,
        r.command, DB_NAME(r.database_id) AS DbName,
        SUBSTRING(t.text, 1, 300) AS SqlText
FROM    sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   r.session_id <> @@SPID AND r.database_id = DB_ID();

SELECT  s.session_id, s.login_name, s.program_name, s.host_name,
        t.transaction_id, t.transaction_begin_time,
        DATEDIFF(SECOND, t.transaction_begin_time, SYSUTCDATETIME()) AS OpenSeconds
FROM    sys.dm_tran_active_transactions AS t
JOIN    sys.dm_tran_session_transactions AS st ON st.transaction_id = t.transaction_id
JOIN    sys.dm_exec_sessions AS s ON s.session_id = st.session_id
WHERE   s.session_id <> @@SPID
ORDER BY t.transaction_begin_time;
GO

/*---------------------------------------------------------------------------
  Section 6 - corroboration. Two strong signals:
   6a  the header was edited and the current header still disagrees with lines
       -> the edit itself is the likely cause
   6b  the lines changed after the last header change
       -> the line side moved and nothing recalculated the header
---------------------------------------------------------------------------*/
PRINT '--- Section 6a: headers edited, still not reconciling ---';
WITH LastAmountChange AS
(
    SELECT  a.OrderId,
            MAX(a.ChangedAt) AS LastAmountChangeAt
    FROM    audit.OrderAudit AS a
    WHERE   a.Action = 'UPDATE' AND a.ChangedColumns LIKE '%Amount%'
    GROUP BY a.OrderId
)
SELECT  v.OrderNumber, v.HeaderAmount, v.LineTotal, v.Variance,
        lac.LastAmountChangeAt, v.LastModifiedBy
FROM    app.vw_OrderVariance AS v
JOIN    LastAmountChange     AS lac ON lac.OrderId = v.OrderId
WHERE   v.Variance <> 0
ORDER BY lac.LastAmountChangeAt DESC;

PRINT '--- Section 6b: lines touched after the header last moved ---';
WITH LastHeaderChange AS
(
    SELECT OrderId, MAX(ChangedAt) AS LastHeaderChangeAt
    FROM   audit.OrderAudit
    GROUP BY OrderId
),
LastLineChange AS
(
    SELECT OrderId, MAX(CreatedAt) AS LastLineCreatedAt, COUNT(*) AS Lines
    FROM   app.OrderLines
    GROUP BY OrderId
)
SELECT  v.OrderNumber, v.HeaderAmount, v.LineTotal, v.Variance,
        lhc.LastHeaderChangeAt, llc.LastLineCreatedAt, llc.Lines
FROM    app.vw_OrderVariance AS v
LEFT JOIN LastHeaderChange   AS lhc ON lhc.OrderId = v.OrderId
LEFT JOIN LastLineChange     AS llc ON llc.OrderId = v.OrderId
WHERE   v.Variance <> 0
  AND   (llc.LastLineCreatedAt > lhc.LastHeaderChangeAt OR lhc.LastHeaderChangeAt IS NULL)
ORDER BY v.OrderNumber;
GO

/*---------------------------------------------------------------------------
  Section 7 - the integrity checks worth running whenever totals are wrong.
  Each should return zero rows on a healthy database.
---------------------------------------------------------------------------*/
PRINT '--- Section 7: integrity checks (all should return 0 rows) ---';

PRINT '7a orphan order lines (FK should make this impossible)';
SELECT l.* FROM app.OrderLines AS l
WHERE NOT EXISTS (SELECT 1 FROM app.Orders o WHERE o.OrderId = l.OrderId);

PRINT '7b duplicate order numbers';
SELECT OrderNumber, COUNT(*) AS Copies
FROM   app.Orders GROUP BY OrderNumber HAVING COUNT(*) > 1;

PRINT '7c orders pointing at a missing or inactive customer';
SELECT o.OrderId, o.OrderNumber, o.CustomerId, c.IsActive
FROM   app.Orders AS o
LEFT JOIN app.Customers AS c ON c.CustomerId = o.CustomerId
WHERE  c.CustomerId IS NULL OR c.IsActive = 0;

PRINT '7d impossible values';
SELECT OrderId, OrderNumber, Amount, OrderDate FROM app.Orders
WHERE  Amount < 0 OR OrderDate > CAST(SYSUTCDATETIME() AS DATE);

PRINT '7e shipped orders with no lines (cannot have shipped nothing)';
SELECT v.OrderNumber, v.Status, v.HeaderAmount
FROM   app.vw_OrderVariance AS v
WHERE  v.Status = N'Shipped' AND v.LineCount = 0;

PRINT '7f orders changed with no audit row - would mean the trigger was off';
SELECT o.OrderId, o.OrderNumber, o.LastModifiedAt, o.LastModifiedBy
FROM   app.Orders AS o
WHERE  o.LastModifiedBy <> N'seed'
  AND  NOT EXISTS (SELECT 1 FROM audit.OrderAudit a WHERE a.OrderId = o.OrderId);

PRINT '7g is the audit trigger actually enabled?';
SELECT  t.name AS TriggerName, OBJECT_NAME(t.parent_id) AS TableName,
        t.is_disabled,
        CASE WHEN t.is_disabled = 1 THEN 'PROBLEM - changes are not being audited'
             ELSE 'OK' END AS Verdict
FROM    sys.triggers AS t
WHERE   t.parent_id IN (OBJECT_ID('app.Orders'), OBJECT_ID('audit.OrderAudit'));
GO

/*---------------------------------------------------------------------------
  Section 8 - one order, end to end. Set @OrderNumber and run. This is the
  block to paste into a ticket when finance asks about a specific order.
---------------------------------------------------------------------------*/
PRINT '--- Section 8: single-order timeline ---';
DECLARE @OrderNumber NVARCHAR(20) = N'SO-1007';   -- <<< set me

SELECT  'header' AS Part, o.OrderId, o.OrderNumber, o.Status, o.Amount,
        o.OrderDate, o.LastModifiedAt, o.LastModifiedBy
FROM    app.Orders AS o WHERE o.OrderNumber = @OrderNumber;

SELECT  'lines' AS Part, l.OrderLineId, l.Sku, l.Qty, l.UnitPrice, l.LineTotal, l.CreatedAt
FROM    app.OrderLines AS l
JOIN    app.Orders     AS o ON o.OrderId = l.OrderId
WHERE   o.OrderNumber = @OrderNumber
ORDER BY l.OrderLineId;

SELECT  'reconciliation' AS Part, v.HeaderAmount, v.LineTotal, v.Variance, v.LineCount
FROM    app.vw_OrderVariance AS v WHERE v.OrderNumber = @OrderNumber;

SELECT  'audit' AS Part, a.AuditId, a.Action, a.ChangedColumns,
        a.OldValues, a.NewValues,
        a.ChangedBy, a.AppUser, a.HostName, a.ProgramName, a.ChangedAt
FROM    audit.OrderAudit AS a
JOIN    app.Orders       AS o ON o.OrderId = a.OrderId
WHERE   o.OrderNumber = @OrderNumber
ORDER BY a.AuditId;
GO

/*---------------------------------------------------------------------------
  Section 9 - the candidate fix list.
  04_datafix_controlled.sql reads fix.OrderAmountCandidates, so the set of
  rows to be changed is decided here, reviewed by a human, and only then
  applied. MISSING_LINES rows are deliberately excluded: zeroing a header
  because its lines vanished would destroy evidence, not fix data.
---------------------------------------------------------------------------*/
PRINT '--- Section 9: building fix.OrderAmountCandidates ---';

DROP TABLE IF EXISTS fix.OrderAmountCandidates;

SELECT  v.OrderId,
        v.OrderNumber,
        v.Status,
        v.HeaderAmount                      AS CurrentAmount,
        v.LineTotal                         AS ProposedAmount,
        v.Variance,
        v.LineCount,
        CASE WHEN v.LineCount = 0 THEN 'MISSING_LINES'
             WHEN v.Variance > 0 THEN 'HEADER_HIGH'
             ELSE 'HEADER_LOW' END          AS Shape,
        CONVERT(BIT, CASE WHEN v.LineCount = 0 THEN 0 ELSE 1 END) AS ApproveForFix,
        CASE WHEN v.LineCount = 0
             THEN 'EXCLUDED - lines are missing; recover the lines, do not rewrite the header'
             ELSE 'Header will be set to the sum of its lines' END AS Note,
        SYSUTCDATETIME()                    AS BuiltAtUtc,
        SUSER_SNAME()                       AS BuiltBy
INTO    fix.OrderAmountCandidates
FROM    app.vw_OrderVariance AS v
WHERE   v.Variance <> 0;

ALTER TABLE fix.OrderAmountCandidates ADD CONSTRAINT PK_OrderAmountCandidates PRIMARY KEY (OrderId);

SELECT * FROM fix.OrderAmountCandidates ORDER BY ApproveForFix DESC, ABS(Variance) DESC;

PRINT '';
PRINT 'Review the list above. To change what gets fixed, UPDATE ApproveForFix';
PRINT 'in fix.OrderAmountCandidates, then run 04_datafix_controlled.sql.';
GO

/*---------------------------------------------------------------------------
  Section 10 - did the nightly reconciliation job run, and did it warn us?
  A discrepancy that the job should have caught, but did not, is a second
  defect: check the job history as well as the data.
---------------------------------------------------------------------------*/
PRINT '--- Section 10a: last reconciliation runs ---';
SELECT TOP (10) RunId, RunStartUtc, RunEndUtc, OrdersChecked,
       VarianceCount, VarianceTotal, Outcome, Message, RunBy
FROM   ops.ReconciliationLog
ORDER BY RunId DESC;

PRINT '--- Section 10b: SQL Agent history for the lab jobs ---';
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'msdb' AND state = 0)
BEGIN
    SELECT  j.name                AS JobName,
            j.enabled             AS IsEnabled,
            h.run_date, h.run_time, h.run_duration,
            CASE h.run_status WHEN 0 THEN 'Failed'    WHEN 1 THEN 'Succeeded'
                              WHEN 2 THEN 'Retry'     WHEN 3 THEN 'Cancelled'
                              WHEN 4 THEN 'In progress' END AS RunStatus,
            h.step_id, h.step_name, h.message
    FROM    msdb.dbo.sysjobs       AS j
    LEFT JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = j.job_id
    WHERE   j.name LIKE 'AppSupportLab%'
    ORDER BY h.run_date DESC, h.run_time DESC, h.step_id;
END
GO

PRINT '=== 03_investigate.sql complete ===';
GO
