/*===========================================================================
  04_datafix_controlled.sql   AppSupportLab - controlled data fix

  Sets app.Orders.Amount to the sum of its lines, for the orders approved in
  fix.OrderAmountCandidates (built by 03_investigate.sql Section 9).

  Shape of the script:
    0  knobs - @DryRun defaults to 1, so a careless run changes NOTHING
    1  pre-flight gates; any failure stops the script before it writes
    2  backup table, taken OUTSIDE the transaction so it survives a rollback
    3  BEGIN TRAN -> UPDATE -> verify -> COMMIT or ROLLBACK
    4  post-fix report
    5  the rollback recipe, if the fix is later judged wrong

  To actually apply the fix:   set @DryRun = 0 below and re-run.
  Run it once, from one session, with the change ticket open.
===========================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT ON;              -- any unhandled error aborts the transaction
USE AppSupportLab;
GO

/*---------------------------------------------------------------------------
  Section 0 - knobs
---------------------------------------------------------------------------*/
DECLARE @DryRun          BIT           = 1;          -- <<< set to 0 to commit
DECLARE @TicketRef       NVARCHAR(50)  = N'INC-0001';-- <<< your change/incident ref
DECLARE @MaxRowsAllowed  INT           = 50;         -- refuse a surprisingly large fix
DECLARE @MaxAbsVariance  DECIMAL(14,2) = 10000.00;   -- refuse a surprisingly large sum

DECLARE @Expected        INT;
DECLARE @ExpectedAbsVar  DECIMAL(14,2);
DECLARE @Updated         INT = 0;
DECLARE @AuditBefore     BIGINT;
DECLARE @AuditAfter      BIGINT;
DECLARE @BackupTable     SYSNAME;
DECLARE @BackupRows      INT = 0;
DECLARE @sql             NVARCHAR(MAX);
DECLARE @Problem         NVARCHAR(500) = NULL;

PRINT CONCAT('Ticket           : ', @TicketRef);
PRINT CONCAT('Mode             : ', CASE WHEN @DryRun = 1 THEN 'DRY RUN (no commit)' ELSE 'APPLY' END);
PRINT CONCAT('Server/Database  : ', @@SERVERNAME, ' / ', DB_NAME());
PRINT CONCAT('Running as       : ', SUSER_SNAME());
PRINT CONCAT('Started (UTC)    : ', CONVERT(CHAR(23), SYSUTCDATETIME(), 126));
PRINT '';

/*---------------------------------------------------------------------------
  Section 1 - pre-flight gates
---------------------------------------------------------------------------*/
PRINT '--- Pre-flight ---';

-- 1.1 the candidate list must exist and have been built recently
IF OBJECT_ID('fix.OrderAmountCandidates') IS NULL
    SET @Problem = 'fix.OrderAmountCandidates does not exist. Run 03_investigate.sql Section 9 first.';

IF @Problem IS NULL
BEGIN
    SELECT  @Expected       = COUNT(*),
            @ExpectedAbsVar = SUM(ABS(Variance))
    FROM    fix.OrderAmountCandidates
    WHERE   ApproveForFix = 1;

    IF ISNULL(@Expected, 0) = 0
        SET @Problem = 'No rows are approved for fix (ApproveForFix = 1). Nothing to do.';
END

-- 1.2 blast-radius gates
IF @Problem IS NULL AND @Expected > @MaxRowsAllowed
    SET @Problem = CONCAT('Refusing to fix ', @Expected, ' rows; @MaxRowsAllowed is ', @MaxRowsAllowed,
                          '. Re-check the candidate list before raising the limit.');

IF @Problem IS NULL AND @ExpectedAbsVar > @MaxAbsVariance
    SET @Problem = CONCAT('Refusing to move ', @ExpectedAbsVar, ' in total; @MaxAbsVariance is ',
                          @MaxAbsVariance, '. Escalate instead of raising the limit.');

-- 1.3 the candidate list must still match live data. If someone changed an
--     order since Section 9 ran, the proposed amount is stale.
IF @Problem IS NULL AND EXISTS
(
    SELECT 1
    FROM   fix.OrderAmountCandidates AS c
    JOIN   app.vw_OrderVariance      AS v ON v.OrderId = c.OrderId
    WHERE  c.ApproveForFix = 1
      AND (v.HeaderAmount <> c.CurrentAmount OR v.LineTotal <> c.ProposedAmount)
)
    SET @Problem = 'Live data has moved since the candidate list was built. Re-run 03_investigate.sql Section 9.';

-- 1.4 the audit trigger must be on, or the fix leaves no trace
IF @Problem IS NULL AND EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE object_id = OBJECT_ID('app.trg_Orders_Audit') AND is_disabled = 1
)
    SET @Problem = 'app.trg_Orders_Audit is disabled. Enable it so the fix is audited, then re-run.';

-- 1.5 approved rows must all have lines; a header with no lines is not fixable here
IF @Problem IS NULL AND EXISTS
    (SELECT 1 FROM fix.OrderAmountCandidates WHERE ApproveForFix = 1 AND LineCount = 0)
    SET @Problem = 'An approved row has no order lines. Recover its lines instead of rewriting the header.';

-- 1.6 do not fight a blocking session
IF @Problem IS NULL AND EXISTS
(
    SELECT 1 FROM sys.dm_exec_requests
    WHERE blocking_session_id <> 0 AND database_id = DB_ID()
)
    SET @Problem = 'Blocking is active in this database. Clear it before applying a data fix.';

IF @Problem IS NOT NULL
BEGIN
    PRINT CONCAT('BLOCKED: ', @Problem);
    THROW 51000, 'Pre-flight failed; nothing was changed.', 1;
END

PRINT CONCAT('Approved rows    : ', @Expected);
PRINT CONCAT('Absolute variance: ', @ExpectedAbsVar);
PRINT 'All pre-flight gates passed.';
PRINT '';

PRINT '--- Rows that will change ---';
SELECT  c.OrderId, c.OrderNumber, c.Status, c.Shape,
        c.CurrentAmount, c.ProposedAmount, c.Variance, c.LineCount
FROM    fix.OrderAmountCandidates AS c
WHERE   c.ApproveForFix = 1
ORDER BY ABS(c.Variance) DESC;

/*---------------------------------------------------------------------------
  Section 2 - backup, OUTSIDE the transaction.

  DDL in SQL Server is transactional, so a backup table created inside the
  transaction would vanish on ROLLBACK - exactly when it is most wanted.
  Creating it first means the pre-change image survives either outcome.
---------------------------------------------------------------------------*/
SET @BackupTable = CONCAT('OrderBackup_', FORMAT(SYSUTCDATETIME(), 'yyyyMMdd_HHmmss'));

SET @sql = CONCAT(N'
SELECT  o.*,
        c.ProposedAmount                  AS ProposedAmount_AtBackup,
        CONVERT(NVARCHAR(50),  ', QUOTENAME(@TicketRef, ''''), N') AS TicketRef,
        SUSER_SNAME()                     AS BackedUpBy,
        SYSUTCDATETIME()                  AS BackedUpAtUtc
INTO    fix.', QUOTENAME(@BackupTable), N'
FROM    app.Orders                AS o
JOIN    fix.OrderAmountCandidates AS c ON c.OrderId = o.OrderId
WHERE   c.ApproveForFix = 1;');

EXEC sys.sp_executesql @sql;

SET @sql = CONCAT(N'SELECT @n = COUNT(*) FROM fix.', QUOTENAME(@BackupTable), N';');
EXEC sys.sp_executesql @sql, N'@n INT OUTPUT', @n = @BackupRows OUTPUT;

PRINT '';
PRINT CONCAT('Backup table     : fix.', @BackupTable, '  (', @BackupRows, ' row(s))');

IF @BackupRows <> @Expected
BEGIN
    PRINT 'BLOCKED: backup row count does not match the approved row count.';
    THROW 51001, 'Backup verification failed; nothing was changed.', 1;
END
PRINT 'Backup verified.';
PRINT '';

/*---------------------------------------------------------------------------
  Section 3 - the transaction
---------------------------------------------------------------------------*/
SELECT @AuditBefore = ISNULL(MAX(AuditId), 0) FROM audit.OrderAudit;

BEGIN TRY
    BEGIN TRANSACTION DataFix;

    -- Tag the session so the audit rows name the ticket, not just the login.
    EXEC sys.sp_set_session_context @key = N'app_user',
                                    @value = @TicketRef, @read_only = 0;

    UPDATE  o
    SET     o.Amount         = c.ProposedAmount,
            o.LastModifiedAt = SYSUTCDATETIME(),
            o.LastModifiedBy = CONCAT(N'datafix:', @TicketRef)
    FROM    app.Orders                AS o
    JOIN    fix.OrderAmountCandidates AS c ON c.OrderId = o.OrderId
    WHERE   c.ApproveForFix = 1
      AND   o.Amount <> c.ProposedAmount;

    SET @Updated = @@ROWCOUNT;

    /*-- verification, all of it inside the transaction --------------------*/
    PRINT '--- Verification (inside transaction) ---';
    PRINT CONCAT('Rows updated     : ', @Updated, '   (expected ', @Expected, ')');

    -- V1 exactly the expected number of rows changed
    IF @Updated <> @Expected
    BEGIN
        SET @Problem = CONCAT('Updated ', @Updated, ' row(s) but expected ', @Expected, '.');
        THROW 51002, 'Row count verification failed.', 1;
    END

    -- V2 every approved order now reconciles
    IF EXISTS
    (
        SELECT 1
        FROM   fix.OrderAmountCandidates AS c
        JOIN   app.vw_OrderVariance      AS v ON v.OrderId = c.OrderId
        WHERE  c.ApproveForFix = 1 AND v.Variance <> 0
    )
    BEGIN
        SELECT 'still out' AS Problem, v.*
        FROM   fix.OrderAmountCandidates AS c
        JOIN   app.vw_OrderVariance      AS v ON v.OrderId = c.OrderId
        WHERE  c.ApproveForFix = 1 AND v.Variance <> 0;
        THROW 51003, 'An approved order still does not reconcile.', 1;
    END
    PRINT 'V2 ok: every approved order reconciles.';

    -- V3 nothing outside the approved set moved
    IF EXISTS
    (
        SELECT 1
        FROM   app.Orders AS o
        LEFT JOIN fix.OrderAmountCandidates AS c
               ON c.OrderId = o.OrderId AND c.ApproveForFix = 1
        WHERE  c.OrderId IS NULL
          AND  o.LastModifiedBy = CONCAT(N'datafix:', @TicketRef)
    )
        THROW 51004, 'An order outside the approved set was modified.', 1;
    PRINT 'V3 ok: no collateral rows changed.';

    -- V4 only Amount (plus the modified-by bookkeeping) changed
    IF EXISTS
    (
        SELECT 1
        FROM   fix.OrderAmountCandidates AS c
        JOIN   app.Orders                AS o ON o.OrderId = c.OrderId
        WHERE  c.ApproveForFix = 1
          AND (o.Status <> c.Status OR o.OrderNumber <> c.OrderNumber)
    )
        THROW 51005, 'A column other than Amount changed on an approved row.', 1;
    PRINT 'V4 ok: only Amount was rewritten.';

    -- V5 the audit trigger recorded one row per changed order
    SELECT @AuditAfter = ISNULL(MAX(AuditId), 0) FROM audit.OrderAudit;
    IF (@AuditAfter - @AuditBefore) <> @Expected
    BEGIN
        SET @Problem = CONCAT('Audit wrote ', @AuditAfter - @AuditBefore,
                              ' row(s), expected ', @Expected, '.');
        THROW 51006, 'Audit verification failed.', 1;
    END
    PRINT CONCAT('V5 ok: audit wrote ', @AuditAfter - @AuditBefore, ' row(s).');

    -- V6 the backup can rebuild the pre-change state
    SET @sql = CONCAT(N'
        SELECT @bad = COUNT(*)
        FROM   fix.', QUOTENAME(@BackupTable), N' AS b
        JOIN   fix.OrderAmountCandidates AS c ON c.OrderId = b.OrderId
        WHERE  b.Amount <> c.CurrentAmount;');
    DECLARE @BadBackup INT;
    EXEC sys.sp_executesql @sql, N'@bad INT OUTPUT', @bad = @BadBackup OUTPUT;
    IF ISNULL(@BadBackup, -1) <> 0
        THROW 51007, 'Backup does not hold the pre-change amounts.', 1;
    PRINT 'V6 ok: backup holds the pre-change amounts.';

    /*-- decide -----------------------------------------------------------*/
    IF @DryRun = 1
    BEGIN
        ROLLBACK TRANSACTION DataFix;
        PRINT '';
        PRINT 'DRY RUN: all verifications passed and the transaction was ROLLED BACK.';
        PRINT 'Set @DryRun = 0 and re-run to apply.';
    END
    ELSE
    BEGIN
        COMMIT TRANSACTION DataFix;
        PRINT '';
        PRINT CONCAT('COMMITTED: ', @Updated, ' order(s) corrected.');
    END
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT '';
    PRINT '*** ROLLED BACK - no data was changed ***';
    PRINT CONCAT('Error ',  ERROR_NUMBER(), ' at line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
    IF @Problem IS NOT NULL PRINT CONCAT('Detail: ', @Problem);
    PRINT CONCAT('The pre-change image is still in fix.', @BackupTable);
    THROW;
END CATCH

EXEC sys.sp_set_session_context @key = N'app_user', @value = NULL;

/*---------------------------------------------------------------------------
  Section 4 - post-fix report
---------------------------------------------------------------------------*/
PRINT '';
PRINT '--- Post-fix state ---';

SELECT  COUNT(*)                                        AS OrdersTotal,
        SUM(CASE WHEN Variance <> 0 THEN 1 ELSE 0 END)  AS StillOut,
        SUM(Variance)                                   AS NetVariance
FROM    app.vw_OrderVariance;

SELECT  'remaining' AS Part, v.OrderNumber, v.Status, v.HeaderAmount,
        v.LineTotal, v.Variance, v.LineCount
FROM    app.vw_OrderVariance AS v
WHERE   v.Variance <> 0
ORDER BY v.OrderNumber;

SELECT  'audit written by this fix' AS Part,
        a.AuditId, o.OrderNumber, a.ChangedColumns,
        JSON_VALUE(a.OldValues, '$.Amount') AS AmountBefore,
        JSON_VALUE(a.NewValues, '$.Amount') AS AmountAfter,
        a.ChangedBy, a.AppUser, a.ChangedAt
FROM    audit.OrderAudit AS a
JOIN    app.Orders       AS o ON o.OrderId = a.OrderId
WHERE   a.AuditId > @AuditBefore
ORDER BY a.AuditId;

INSERT ops.ReconciliationLog
    (RunStartUtc, RunEndUtc, OrdersChecked, VarianceCount, VarianceTotal, Outcome, Message)
SELECT  SYSUTCDATETIME(), SYSUTCDATETIME(),
        (SELECT COUNT(*) FROM app.Orders),
        (SELECT COUNT(*) FROM app.vw_OrderVariance WHERE Variance <> 0),
        (SELECT ISNULL(SUM(Variance), 0) FROM app.vw_OrderVariance WHERE Variance <> 0),
        CASE WHEN @DryRun = 1 THEN N'OK' ELSE N'VARIANCES' END,
        CONCAT(N'04_datafix_controlled.sql ',
               CASE WHEN @DryRun = 1 THEN N'dry run' ELSE N'applied' END,
               N' for ', @TicketRef, N'; rows=', @Updated,
               N'; backup=fix.', @BackupTable);

PRINT '';
PRINT '--- Rollback recipe, if this fix is later judged wrong ---';
PRINT CONCAT('
BEGIN TRANSACTION;
    UPDATE  o
    SET     o.Amount         = b.Amount,
            o.LastModifiedAt = SYSUTCDATETIME(),
            o.LastModifiedBy = N''rollback:', @TicketRef, '''
    FROM    app.Orders AS o
    JOIN    fix.', @BackupTable, ' AS b ON b.OrderId = o.OrderId;
    -- expect ', @Expected, ' row(s); check, then COMMIT or ROLLBACK
SELECT @@ROWCOUNT AS RowsRestored;
-- COMMIT TRANSACTION;   -- or ROLLBACK TRANSACTION;');

PRINT '';
PRINT '=== 04_datafix_controlled.sql complete ===';
GO
