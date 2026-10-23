/*===========================================================================
  05_sqlagent_jobs.sql   AppSupportLab - reconciliation proc + SQL Agent jobs

  IMPORTANT EDITION NOTE
  ----------------------
  SQL Server EXPRESS does not include SQL Server Agent. The service
  SQLAgent$SQLEXPRESS exists but cannot be started, and msdb's job tables are
  present but unusable. So:

    * Sections 1-2 (the reconciliation proc) run on ANY edition, Express
      included, and are what the app and the health check depend on.
    * Section 3 (the Agent jobs) needs Developer or Standard edition.
      Developer edition is free and full-featured - use it if you want the
      SQL Agent half of this lab.
    * Section 4 prints the Windows Scheduled Task equivalent for Express.

  The script detects the edition and skips Section 3 rather than failing.
===========================================================================*/

SET NOCOUNT ON;
USE AppSupportLab;
GO

/*---------------------------------------------------------------------------
  Section 1 - the nightly reconciliation proc.

  Writes one row to ops.ReconciliationLog per run and, when variances exist,
  RAISERRORs at severity 16 so the Agent job step is recorded as FAILED. A
  job that "succeeds" while the data is wrong teaches nobody anything.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE ops.usp_ReconcileOrderTotals
    @FailOnVariance BIT = 1,
    @MaxVarianceAllowed DECIMAL(14,2) = 0.00
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunId         INT;
    DECLARE @Checked       INT;
    DECLARE @VarCount      INT;
    DECLARE @VarTotal      DECIMAL(14,2);
    DECLARE @Outcome       NVARCHAR(20);
    DECLARE @Message       NVARCHAR(2000);

    INSERT ops.ReconciliationLog (RunStartUtc) VALUES (SYSUTCDATETIME());
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT  @Checked  = COUNT(*),
                @VarCount = SUM(CASE WHEN Variance <> 0 THEN 1 ELSE 0 END),
                @VarTotal = ISNULL(SUM(CASE WHEN Variance <> 0 THEN ABS(Variance) END), 0)
        FROM    app.vw_OrderVariance;

        SET @VarCount = ISNULL(@VarCount, 0);
        SET @Outcome  = CASE WHEN @VarCount = 0 THEN N'OK' ELSE N'VARIANCES' END;

        IF @VarCount = 0
            SET @Message = N'All order headers reconcile with their lines.';
        ELSE
            SET @Message = CONCAT(N'Orders failing reconciliation: ', @VarCount,
                                  N'; absolute variance ', @VarTotal, N'. Worst: ',
                (SELECT STRING_AGG(CONCAT(OrderNumber, N' (', Variance, N')'), N', ')
                 FROM (SELECT TOP (5) OrderNumber, Variance
                       FROM   app.vw_OrderVariance
                       WHERE  Variance <> 0
                       ORDER BY ABS(Variance) DESC) AS worst));

        UPDATE ops.ReconciliationLog
        SET    RunEndUtc = SYSUTCDATETIME(), OrdersChecked = @Checked,
               VarianceCount = @VarCount, VarianceTotal = @VarTotal,
               Outcome = @Outcome, Message = @Message
        WHERE  RunId = @RunId;

        PRINT CONCAT('Run ', @RunId, ': ', @Outcome, ' - ', @Message);

        IF @FailOnVariance = 1 AND @VarTotal > @MaxVarianceAllowed
        BEGIN
            -- RAISERROR's %s takes a string, never a DECIMAL, so convert first.
            DECLARE @VarTotalText NVARCHAR(30) = CONVERT(NVARCHAR(30), @VarTotal);
            RAISERROR('Reconciliation found %d order(s) out by %s in total. See ops.ReconciliationLog RunId %d.',
                      16, 1, @VarCount, @VarTotalText, @RunId);
        END
    END TRY
    BEGIN CATCH
        -- Record the failure, then re-raise so the job step fails too.
        UPDATE ops.ReconciliationLog
        SET    RunEndUtc = SYSUTCDATETIME(),
               Outcome   = CASE WHEN ERROR_NUMBER() = 50000 THEN N'VARIANCES' ELSE N'FAILED' END,
               Message   = CONCAT(ISNULL(Message, N''), N' | error ', ERROR_NUMBER(),
                                  N': ', ERROR_MESSAGE())
        WHERE  RunId = @RunId;
        THROW;
    END CATCH
END
GO
PRINT 'Created or altered ops.usp_ReconcileOrderTotals';
GO

/*---------------------------------------------------------------------------
  Section 2 - prove the proc works before wiring a job to it
---------------------------------------------------------------------------*/
PRINT '--- Smoke test: reconciliation proc, non-failing mode ---';
EXEC ops.usp_ReconcileOrderTotals @FailOnVariance = 0;
SELECT TOP (3) RunId, RunStartUtc, OrdersChecked, VarianceCount, VarianceTotal, Outcome, Message
FROM   ops.ReconciliationLog ORDER BY RunId DESC;
GO

/*---------------------------------------------------------------------------
  Section 3 - SQL Agent jobs. Skipped automatically on Express.
---------------------------------------------------------------------------*/
DECLARE @Edition NVARCHAR(128) = CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'));

IF @Edition LIKE '%Express%'
BEGIN
    PRINT '';
    PRINT CONCAT('Edition is "', @Edition, '" - SQL Server Agent is not available.');
    PRINT 'Skipping Section 3. Use Section 4 (Windows Scheduled Task) instead,';
    PRINT 'or rebuild the lab on Developer edition to exercise Agent jobs.';
END
ELSE
BEGIN
    PRINT '';
    PRINT CONCAT('Edition is "', @Edition, '" - creating SQL Agent jobs.');

    DECLARE @sql NVARCHAR(MAX) = N'
    USE msdb;

    /*--- job 1: nightly reconciliation -----------------------------------*/
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N''AppSupportLab - Nightly Order Reconciliation'')
        EXEC msdb.dbo.sp_delete_job @job_name = N''AppSupportLab - Nightly Order Reconciliation'', @delete_unused_schedule = 1;

    EXEC msdb.dbo.sp_add_job
        @job_name    = N''AppSupportLab - Nightly Order Reconciliation'',
        @enabled     = 1,
        @description = N''Checks every order header against its line totals. Fails the step when any order is out, so the failure is visible in job history and to the health check.'',
        @category_name = N''[Uncategorized (Local)]'',
        @owner_login_name = N''sa'';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name   = N''AppSupportLab - Nightly Order Reconciliation'',
        @step_name  = N''Reconcile order totals'',
        @subsystem  = N''TSQL'',
        @database_name = N''AppSupportLab'',
        @command    = N''EXEC ops.usp_ReconcileOrderTotals @FailOnVariance = 1;'',
        @retry_attempts = 1,
        @retry_interval = 5,
        @on_success_action = 1,   /* quit with success */
        @on_fail_action    = 2;   /* quit with failure */

    EXEC msdb.dbo.sp_add_jobschedule
        @job_name       = N''AppSupportLab - Nightly Order Reconciliation'',
        @name           = N''Daily 02:00'',
        @freq_type      = 4,      /* daily */
        @freq_interval  = 1,
        @active_start_time = 020000;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N''AppSupportLab - Nightly Order Reconciliation'',
        @server_name = N''(LOCAL)'';

    /*--- job 2: weekly audit purge ---------------------------------------*/
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N''AppSupportLab - Weekly Audit Purge'')
        EXEC msdb.dbo.sp_delete_job @job_name = N''AppSupportLab - Weekly Audit Purge'', @delete_unused_schedule = 1;

    EXEC msdb.dbo.sp_add_job
        @job_name    = N''AppSupportLab - Weekly Audit Purge'',
        @enabled     = 1,
        @description = N''Ages audit.OrderAudit out beyond the retention window.'',
        @owner_login_name = N''sa'';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name   = N''AppSupportLab - Weekly Audit Purge'',
        @step_name  = N''Purge audit rows'',
        @subsystem  = N''TSQL'',
        @database_name = N''AppSupportLab'',
        @command    = N''EXEC ops.usp_PurgeOrderAudit @RetainDays = 365;'',
        @on_success_action = 1,
        @on_fail_action    = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_name       = N''AppSupportLab - Weekly Audit Purge'',
        @name           = N''Sunday 03:00'',
        @freq_type      = 8,      /* weekly */
        @freq_interval  = 1,      /* Sunday */
        @freq_recurrence_factor = 1,
        @active_start_time = 030000;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N''AppSupportLab - Weekly Audit Purge'',
        @server_name = N''(LOCAL)'';
    ';

    EXEC sys.sp_executesql @sql;

    PRINT 'Jobs created. Current state:';
    SELECT  j.name, j.enabled, j.date_created,
            s.name AS ScheduleName, s.freq_type, s.active_start_time
    FROM    msdb.dbo.sysjobs AS j
    LEFT JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
    LEFT JOIN msdb.dbo.sysschedules    AS s  ON s.schedule_id = js.schedule_id
    WHERE   j.name LIKE 'AppSupportLab%';

    PRINT 'Run one now with:';
    PRINT '  EXEC msdb.dbo.sp_start_job @job_name = N''AppSupportLab - Nightly Order Reconciliation'';';
END
GO

/*---------------------------------------------------------------------------
  Section 4 - Express fallback: drive the proc from a Windows Scheduled Task.
  Printed, not executed; run it from an elevated PowerShell prompt.
---------------------------------------------------------------------------*/
PRINT '';
PRINT '--- Express fallback: Windows Scheduled Task equivalent ---';
PRINT '
# Run from an elevated PowerShell prompt on the lab VM.
$action  = New-ScheduledTaskAction -Execute "sqlcmd.exe" `
           -Argument ''-S localhost\SQLEXPRESS -d AppSupportLab -E -b -Q "EXEC ops.usp_ReconcileOrderTotals @FailOnVariance = 1;"''
$trigger = New-ScheduledTaskTrigger -Daily -At 2:00am
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "AppSupportLab - Nightly Order Reconciliation" `
    -Action $action -Trigger $trigger -Principal $principal `
    -Description "Express stand-in for the SQL Agent reconciliation job."

# sqlcmd -b makes a T-SQL error set a non-zero exit code, so the task
# history shows the failure the same way Agent job history would.
Start-ScheduledTask -TaskName "AppSupportLab - Nightly Order Reconciliation"
Get-ScheduledTaskInfo -TaskName "AppSupportLab - Nightly Order Reconciliation"
';

PRINT '=== 05_sqlagent_jobs.sql complete ===';
GO
