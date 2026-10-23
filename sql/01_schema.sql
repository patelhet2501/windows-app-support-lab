/*===========================================================================
  01_schema.sql   AppSupportLab - schema, audit table, audit trigger

  Target : SQL Server 2019 or 2022 (Express or Developer). CONCAT_WS and
           SESSION_CONTEXT need 2017+, so do not run this against 2016.
  Run as : a sysadmin (the lab installer does), from sqlcmd or SSMS.
  Safe to re-run: objects are created only when missing, and the trigger and
           views use CREATE OR ALTER.

  The business rule the whole lab turns on:
      app.Orders.Amount must equal SUM(app.OrderLines.LineTotal) for the order.
  Nothing enforces that at write time - deliberately. That is the data
  discrepancy 03_investigate.sql hunts and 04_datafix_controlled.sql repairs.
===========================================================================*/

SET NOCOUNT ON;
GO

IF DB_ID('AppSupportLab') IS NULL
BEGIN
    PRINT 'Creating database AppSupportLab';
    EXEC('CREATE DATABASE AppSupportLab');
END
ELSE
    PRINT 'Database AppSupportLab already exists';
GO

ALTER DATABASE AppSupportLab SET RECOVERY SIMPLE;   -- lab only; full recovery in production
GO

USE AppSupportLab;
GO

/*--- schemas --------------------------------------------------------------*/
IF SCHEMA_ID('app')   IS NULL EXEC('CREATE SCHEMA app   AUTHORIZATION dbo');
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit AUTHORIZATION dbo');
IF SCHEMA_ID('ops')   IS NULL EXEC('CREATE SCHEMA ops   AUTHORIZATION dbo');
IF SCHEMA_ID('fix')   IS NULL EXEC('CREATE SCHEMA fix   AUTHORIZATION dbo');  -- holds data-fix backups
GO

/*--- app.Customers --------------------------------------------------------*/
IF OBJECT_ID('app.Customers') IS NULL
BEGIN
    CREATE TABLE app.Customers
    (
        CustomerId  INT            IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
        Name        NVARCHAR(100)  NOT NULL,
        Email       NVARCHAR(256)  NULL,
        Region      NVARCHAR(20)   NOT NULL
            CONSTRAINT DF_Customers_Region DEFAULT N'UNKNOWN',
        IsActive    BIT            NOT NULL
            CONSTRAINT DF_Customers_IsActive DEFAULT 1,
        CreatedAt   DATETIME2(3)   NOT NULL
            CONSTRAINT DF_Customers_CreatedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_Customers_Email ON app.Customers(Email) WHERE Email IS NOT NULL;
    PRINT 'Created app.Customers';
END
GO

/*--- app.Orders -----------------------------------------------------------*/
IF OBJECT_ID('app.Orders') IS NULL
BEGIN
    CREATE TABLE app.Orders
    (
        OrderId        INT            IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
        OrderNumber    NVARCHAR(20)   NOT NULL
            CONSTRAINT UQ_Orders_OrderNumber UNIQUE,
        CustomerId     INT            NOT NULL
            CONSTRAINT FK_Orders_Customers REFERENCES app.Customers(CustomerId),
        Status         NVARCHAR(20)   NOT NULL
            CONSTRAINT DF_Orders_Status DEFAULT N'New'
            CONSTRAINT CK_Orders_Status CHECK (Status IN (N'New', N'Picked', N'Shipped', N'Cancelled')),
        -- Deliberately NOT a computed column: the app writes it, so it can drift.
        Amount         DECIMAL(12,2)  NOT NULL
            CONSTRAINT DF_Orders_Amount DEFAULT 0
            CONSTRAINT CK_Orders_Amount CHECK (Amount >= 0),
        OrderDate      DATE           NOT NULL
            CONSTRAINT DF_Orders_OrderDate DEFAULT CAST(SYSUTCDATETIME() AS DATE),
        LastModifiedAt DATETIME2(3)   NOT NULL
            CONSTRAINT DF_Orders_LastModifiedAt DEFAULT SYSUTCDATETIME(),
        LastModifiedBy NVARCHAR(128)  NOT NULL
            CONSTRAINT DF_Orders_LastModifiedBy DEFAULT SUSER_SNAME()
    );
    CREATE INDEX IX_Orders_CustomerId ON app.Orders(CustomerId);
    CREATE INDEX IX_Orders_Status_OrderDate ON app.Orders(Status, OrderDate) INCLUDE (Amount);
    PRINT 'Created app.Orders';
END
GO

/*--- app.OrderLines -------------------------------------------------------*/
IF OBJECT_ID('app.OrderLines') IS NULL
BEGIN
    CREATE TABLE app.OrderLines
    (
        OrderLineId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_OrderLines PRIMARY KEY CLUSTERED,
        OrderId     INT           NOT NULL
            CONSTRAINT FK_OrderLines_Orders REFERENCES app.Orders(OrderId),
        Sku         NVARCHAR(30)  NOT NULL,
        Qty         INT           NOT NULL
            CONSTRAINT CK_OrderLines_Qty CHECK (Qty > 0),
        UnitPrice   DECIMAL(12,2) NOT NULL
            CONSTRAINT CK_OrderLines_UnitPrice CHECK (UnitPrice >= 0),
        -- The line side IS trustworthy; only the header can drift.
        LineTotal   AS (CONVERT(DECIMAL(12,2), Qty * UnitPrice)) PERSISTED,
        CreatedAt   DATETIME2(3)  NOT NULL
            CONSTRAINT DF_OrderLines_CreatedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_OrderLines_OrderId ON app.OrderLines(OrderId) INCLUDE (LineTotal);
    PRINT 'Created app.OrderLines';
END
GO

/*--- audit.OrderAudit -----------------------------------------------------
  One row per affected order per DML statement. Old and new images are stored
  as JSON so the table never needs altering when app.Orders gains a column.
  ChangedBy  = the SQL principal (the IIS app-pool identity, in the lab)
  AppUser    = the end user the app passed via sp_set_session_context
-------------------------------------------------------------------------*/
IF OBJECT_ID('audit.OrderAudit') IS NULL
BEGIN
    CREATE TABLE audit.OrderAudit
    (
        AuditId        BIGINT         IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_OrderAudit PRIMARY KEY CLUSTERED,
        OrderId        INT            NOT NULL,
        Action         CHAR(6)        NOT NULL
            CONSTRAINT CK_OrderAudit_Action CHECK (Action IN ('INSERT', 'UPDATE', 'DELETE')),
        ChangedColumns NVARCHAR(500)  NULL,     -- NULL for INSERT and DELETE
        OldValues      NVARCHAR(MAX)  NULL
            CONSTRAINT CK_OrderAudit_OldJson CHECK (OldValues IS NULL OR ISJSON(OldValues) = 1),
        NewValues      NVARCHAR(MAX)  NULL
            CONSTRAINT CK_OrderAudit_NewJson CHECK (NewValues IS NULL OR ISJSON(NewValues) = 1),
        ChangedBy      NVARCHAR(128)  NOT NULL,
        AppUser        NVARCHAR(128)  NULL,
        HostName       NVARCHAR(128)  NULL,
        ProgramName    NVARCHAR(128)  NULL,
        SessionId      SMALLINT       NULL,
        TransactionId  BIGINT         NULL,
        ChangedAt      DATETIME2(3)   NOT NULL
            CONSTRAINT DF_OrderAudit_ChangedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_OrderAudit_OrderId_ChangedAt ON audit.OrderAudit(OrderId, ChangedAt DESC);
    CREATE INDEX IX_OrderAudit_ChangedAt ON audit.OrderAudit(ChangedAt DESC);
    PRINT 'Created audit.OrderAudit';
END
GO

/*--- ops.ReconciliationLog ------------------------------------------------
  What the nightly SQL Agent job writes. The health check reads it to answer
  "did the overnight reconciliation run, and did it find anything?".
-------------------------------------------------------------------------*/
IF OBJECT_ID('ops.ReconciliationLog') IS NULL
BEGIN
    CREATE TABLE ops.ReconciliationLog
    (
        RunId           INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ReconciliationLog PRIMARY KEY CLUSTERED,
        RunStartUtc     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ReconLog_Start DEFAULT SYSUTCDATETIME(),
        RunEndUtc       DATETIME2(3)  NULL,
        OrdersChecked   INT           NULL,
        VarianceCount   INT           NULL,
        VarianceTotal   DECIMAL(14,2) NULL,
        Outcome         NVARCHAR(20)  NULL,     -- OK | VARIANCES | FAILED
        Message         NVARCHAR(2000) NULL,
        RunBy           NVARCHAR(128) NOT NULL
            CONSTRAINT DF_ReconLog_RunBy DEFAULT SUSER_SNAME()
    );
    PRINT 'Created ops.ReconciliationLog';
END
GO

/*===========================================================================
  The audit trigger.

  Handles INSERT, UPDATE and DELETE in one definition, multi-row statements
  included, via FULL OUTER JOIN of inserted and deleted on the key.

  Column-change detection uses the null-safe
      EXISTS (SELECT i.Col EXCEPT SELECT d.Col)
  idiom, so a value going to or from NULL counts as a change - a plain
  i.Col <> d.Col would silently miss those.
===========================================================================*/
CREATE OR ALTER TRIGGER app.trg_Orders_Audit
ON app.Orders
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- An UPDATE that matched no rows still fires the trigger; do no work.
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
        RETURN;

    INSERT audit.OrderAudit
    (
        OrderId, Action, ChangedColumns, OldValues, NewValues,
        ChangedBy, AppUser, HostName, ProgramName, SessionId, TransactionId
    )
    SELECT
        COALESCE(i.OrderId, d.OrderId),
        CASE WHEN d.OrderId IS NULL THEN 'INSERT'
             WHEN i.OrderId IS NULL THEN 'DELETE'
             ELSE 'UPDATE'
        END,
        CASE WHEN i.OrderId IS NOT NULL AND d.OrderId IS NOT NULL THEN
            NULLIF(CONCAT_WS(N',',
                CASE WHEN EXISTS (SELECT i.OrderNumber    EXCEPT SELECT d.OrderNumber)    THEN N'OrderNumber'    END,
                CASE WHEN EXISTS (SELECT i.CustomerId     EXCEPT SELECT d.CustomerId)     THEN N'CustomerId'     END,
                CASE WHEN EXISTS (SELECT i.Status         EXCEPT SELECT d.Status)         THEN N'Status'         END,
                CASE WHEN EXISTS (SELECT i.Amount         EXCEPT SELECT d.Amount)         THEN N'Amount'         END,
                CASE WHEN EXISTS (SELECT i.OrderDate      EXCEPT SELECT d.OrderDate)      THEN N'OrderDate'      END,
                CASE WHEN EXISTS (SELECT i.LastModifiedBy EXCEPT SELECT d.LastModifiedBy) THEN N'LastModifiedBy' END
            ), N'')
        END,
        CASE WHEN d.OrderId IS NULL THEN NULL ELSE
            (SELECT d.OrderId        AS OrderId,
                    d.OrderNumber    AS OrderNumber,
                    d.CustomerId     AS CustomerId,
                    d.Status         AS Status,
                    d.Amount         AS Amount,
                    d.OrderDate      AS OrderDate,
                    d.LastModifiedAt AS LastModifiedAt,
                    d.LastModifiedBy AS LastModifiedBy
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        END,
        CASE WHEN i.OrderId IS NULL THEN NULL ELSE
            (SELECT i.OrderId        AS OrderId,
                    i.OrderNumber    AS OrderNumber,
                    i.CustomerId     AS CustomerId,
                    i.Status         AS Status,
                    i.Amount         AS Amount,
                    i.OrderDate      AS OrderDate,
                    i.LastModifiedAt AS LastModifiedAt,
                    i.LastModifiedBy AS LastModifiedBy
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        END,
        SUSER_SNAME(),
        CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'app_user')),
        HOST_NAME(),
        PROGRAM_NAME(),
        @@SPID,
        CURRENT_TRANSACTION_ID()
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d
        ON d.OrderId = i.OrderId;
END
GO
PRINT 'Created or altered app.trg_Orders_Audit';
GO

/*--- the audit trail must not be rewritable by the application ------------*/
CREATE OR ALTER TRIGGER audit.trg_OrderAudit_NoTamper
ON audit.OrderAudit
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50001, 'audit.OrderAudit is append-only. Purge via ops.usp_PurgeOrderAudit.', 1;
END
GO
PRINT 'Created or altered audit.trg_OrderAudit_NoTamper';
GO

/*--- the one sanctioned way to age the audit trail out --------------------*/
CREATE OR ALTER PROCEDURE ops.usp_PurgeOrderAudit
    @RetainDays INT = 365,
    @BatchSize  INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    IF @RetainDays < 30
        THROW 50002, 'Refusing to purge audit history younger than 30 days.', 1;

    DECLARE @cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());
    DECLARE @removed INT = 1, @total INT = 0;

    -- The INSTEAD OF trigger blocks DELETE, so disable it for this one proc.
    DISABLE TRIGGER audit.trg_OrderAudit_NoTamper ON audit.OrderAudit;
    BEGIN TRY
        WHILE @removed > 0
        BEGIN
            DELETE TOP (@BatchSize) FROM audit.OrderAudit WHERE ChangedAt < @cutoff;
            SET @removed = @@ROWCOUNT;
            SET @total  += @removed;
        END
    END TRY
    BEGIN CATCH
        ENABLE TRIGGER audit.trg_OrderAudit_NoTamper ON audit.OrderAudit;
        THROW;
    END CATCH
    ENABLE TRIGGER audit.trg_OrderAudit_NoTamper ON audit.OrderAudit;

    PRINT CONCAT('Purged ', @total, ' audit row(s) older than ', CONVERT(CHAR(23), @cutoff, 126));
END
GO

/*--- views the app and the investigation scripts share --------------------*/
CREATE OR ALTER VIEW app.vw_OrderVariance
AS
SELECT  o.OrderId,
        o.OrderNumber,
        o.CustomerId,
        o.Status,
        o.Amount                                        AS HeaderAmount,
        COALESCE(SUM(l.LineTotal), 0)                   AS LineTotal,
        o.Amount - COALESCE(SUM(l.LineTotal), 0)        AS Variance,
        COUNT(l.OrderLineId)                            AS LineCount,
        o.LastModifiedAt,
        o.LastModifiedBy
FROM    app.Orders AS o
LEFT JOIN app.OrderLines AS l ON l.OrderId = o.OrderId
GROUP BY o.OrderId, o.OrderNumber, o.CustomerId, o.Status, o.Amount,
         o.LastModifiedAt, o.LastModifiedBy;
GO
PRINT 'Created or altered app.vw_OrderVariance';
GO

PRINT '=== 01_schema.sql complete ===';
GO
