/*===========================================================================
  02_seed.sql   AppSupportLab - seed data, including planted discrepancies

  Loads 6 customers, 12 orders and their lines. Three orders are seeded with
  a header Amount that does not match their lines, and one order is seeded
  with no lines at all, so 03_investigate.sql has something real to find.

  Re-running this script resets the data to its starting state. It truncates
  the order tables and the audit trail, so do not run it after you have begun
  an investigation you care about.
===========================================================================*/

SET NOCOUNT ON;
USE AppSupportLab;
GO

PRINT 'Resetting data...';

-- Child first, and the audit trigger must not fire for the reset itself.
DISABLE TRIGGER app.trg_Orders_Audit ON app.Orders;
DISABLE TRIGGER audit.trg_OrderAudit_NoTamper ON audit.OrderAudit;

DELETE FROM app.OrderLines;
DELETE FROM app.Orders;
DELETE FROM app.Customers;
DELETE FROM audit.OrderAudit;
DELETE FROM ops.ReconciliationLog;

ENABLE TRIGGER audit.trg_OrderAudit_NoTamper ON audit.OrderAudit;

DBCC CHECKIDENT ('app.Customers',  RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('app.Orders',      RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('app.OrderLines',  RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('audit.OrderAudit', RESEED, 0) WITH NO_INFOMSGS;
GO

/*--- customers ------------------------------------------------------------*/
INSERT app.Customers (Name, Email, Region) VALUES
    (N'Northwind Supply',   N'ap@northwind.example',    N'EAST'),
    (N'Harbour Foods',      N'orders@harbour.example',  N'EAST'),
    (N'Cedar Lane Grocers', N'ap@cedarlane.example',    N'WEST'),
    (N'Pinebrook Cafe',     N'owner@pinebrook.example', N'WEST'),
    (N'Lakeside Catering',  N'ap@lakeside.example',     N'NORTH'),
    (N'Dockyard Deli',      NULL,                       N'SOUTH');
GO

/*--- orders ---------------------------------------------------------------
  Amount is seeded as the CORRECT total here; the discrepancies are applied
  further down, each with a comment explaining the real-world cause it mimics.
-------------------------------------------------------------------------*/
INSERT app.Orders (OrderNumber, CustomerId, Status, Amount, OrderDate, LastModifiedBy) VALUES
    (N'SO-1001', 1, N'Shipped',   1250.00, '2026-09-28', N'seed'),
    (N'SO-1002', 1, N'Shipped',    430.50, '2026-09-29', N'seed'),
    (N'SO-1003', 2, N'Picked',    2190.00, '2026-10-01', N'seed'),
    (N'SO-1004', 3, N'New',        310.75, '2026-10-03', N'seed'),
    (N'SO-1005', 3, N'Shipped',    985.20, '2026-10-05', N'seed'),
    (N'SO-1006', 4, N'Cancelled',    0.00, '2026-10-07', N'seed'),
    (N'SO-1007', 4, N'Shipped',   1575.00, '2026-10-09', N'seed'),
    (N'SO-1008', 5, N'Picked',     640.00, '2026-10-12', N'seed'),
    (N'SO-1009', 5, N'New',       3120.40, '2026-10-15', N'seed'),
    (N'SO-1010', 6, N'Shipped',    205.00, '2026-10-17', N'seed'),
    (N'SO-1011', 2, N'Shipped',    878.25, '2026-10-19', N'seed'),
    (N'SO-1012', 1, N'New',       1460.00, '2026-10-21', N'seed');
GO

/*--- order lines ----------------------------------------------------------*/
INSERT app.OrderLines (OrderId, Sku, Qty, UnitPrice) VALUES
    ( 1, N'FLOUR-25KG',    10,  45.00),  ( 1, N'SUGAR-10KG',    20,  40.00),
    ( 2, N'OLIVE-5L',       7,  61.50),
    ( 3, N'COFFEE-1KG',    30,  53.00),  ( 3, N'FILTER-100',    20,  30.00),
    ( 4, N'TEA-500G',      15,  20.65),  ( 4, N'HONEY-1KG',      1,   1.00),
    ( 5, N'RICE-20KG',     12,  58.10),  ( 5, N'LENTIL-10KG',    6,  48.00),
    /* order 6 is Cancelled with amount 0 and no lines - legitimate, and a
       useful false positive to rule out while investigating. */
    ( 7, N'BEEF-5KG',      15, 105.00),
    ( 8, N'NAPKIN-CS',     16,  40.00),
    ( 9, N'CHEESE-2KG',    28, 102.00),  ( 9, N'BUTTER-5KG',     4,  66.10),
    (10, N'BREAD-TRAY',    10,  20.50),
    (11, N'SALMON-3KG',     5, 125.65),  (11, N'LEMON-CS',       5,  50.00),
    (12, N'POTATO-25KG',   20,  73.00);
GO

-- Confirm the baseline is clean before we plant anything.
IF EXISTS (SELECT 1 FROM app.vw_OrderVariance WHERE Variance <> 0 AND LineCount > 0)
BEGIN
    SELECT 'Baseline is not clean - check the seed values' AS Problem, *
    FROM app.vw_OrderVariance WHERE Variance <> 0 AND LineCount > 0;
    THROW 50010, 'Seed baseline does not reconcile. Fix 02_seed.sql before continuing.', 1;
END
PRINT 'Baseline reconciles.';
GO

/*===========================================================================
  Planted discrepancies. Each is a cause you actually meet in support work.
  The audit trigger is left ENABLED for these so the audit trail shows them -
  that is the point: the investigation should be able to find who did it.
===========================================================================*/

-- (1) A partial refund was applied to the lines but the header was never
--     recalculated: header is now too high by 90.00.
EXEC sys.sp_set_session_context @key = N'app_user', @value = N'batch\nightly_refund';
UPDATE app.Orders
SET    Amount = Amount,                      -- header untouched, lines reduced
       LastModifiedAt = SYSUTCDATETIME(),
       LastModifiedBy = N'batch\nightly_refund'
WHERE  OrderNumber = N'SO-1003';
UPDATE app.OrderLines SET Qty = Qty - 3 WHERE OrderId = 3 AND Sku = N'FILTER-100';
GO

-- (2) A manual header edit in SSMS, fat-fingered: 1575.00 typed as 1557.00.
EXEC sys.sp_set_session_context @key = N'app_user', @value = N'CORP\jsmith';
UPDATE app.Orders
SET    Amount = 1557.00,
       LastModifiedAt = SYSUTCDATETIME(),
       LastModifiedBy = N'CORP\jsmith'
WHERE  OrderNumber = N'SO-1007';
GO

-- (3) A line was added by an integration that does not maintain the header,
--     so the header is now too low.
EXEC sys.sp_set_session_context @key = N'app_user', @value = N'svc\edi_import';
INSERT app.OrderLines (OrderId, Sku, Qty, UnitPrice)
SELECT OrderId, N'DELIVERY-FEE', 1, 95.00 FROM app.Orders WHERE OrderNumber = N'SO-1010';
GO

-- (4) An order whose lines were deleted by a cleanup script while the header
--     kept its amount: looks like a missing-lines orphan.
EXEC sys.sp_set_session_context @key = N'app_user', @value = N'CORP\cleanup_task';
DELETE FROM app.OrderLines WHERE OrderId = (SELECT OrderId FROM app.Orders WHERE OrderNumber = N'SO-1008');
GO

EXEC sys.sp_set_session_context @key = N'app_user', @value = NULL;
ENABLE TRIGGER app.trg_Orders_Audit ON app.Orders;
GO

/*--- what we just built ---------------------------------------------------*/
PRINT '';
PRINT 'Seeded. Planted discrepancies:';
SELECT  OrderNumber, Status, HeaderAmount, LineTotal, Variance, LineCount
FROM    app.vw_OrderVariance
WHERE   Variance <> 0
ORDER BY OrderNumber;

PRINT 'Audit rows written during seeding:';
SELECT AuditId, OrderId, Action, ChangedColumns, AppUser, ChangedAt
FROM   audit.OrderAudit ORDER BY AuditId;

PRINT '=== 02_seed.sql complete ===';
GO
