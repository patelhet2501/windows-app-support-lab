-- sqlite_smoke.sql - DEV ONLY offline smoke-test schema.
--
-- The canonical schema is sql/01_schema.sql (T-SQL). This file mirrors it in
-- SQLite so the Flask app can be exercised on a workstation with no SQL
-- Server, which is useful for checking the app's own code paths before
-- deploying to the lab VM. It deliberately keeps the same table and column
-- names, the same header-vs-lines rule, and an audit trigger with the same
-- shape, so the app's queries need no special-casing beyond schema prefixes.
--
-- Do NOT use this on the lab VM. It proves nothing about SQL Server.

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS OrderAudit;
DROP TABLE IF EXISTS session_context;
DROP TABLE IF EXISTS OrderLines;
DROP TABLE IF EXISTS Orders;
DROP TABLE IF EXISTS Customers;

-- Stands in for SQL Server's SESSION_CONTEXT. The audit triggers read the
-- acting user from here; app/db.py rewrites the single row per connection.
CREATE TABLE session_context (app_user TEXT);
INSERT INTO session_context (app_user) VALUES ('seed');

CREATE TABLE Customers (
    CustomerId INTEGER PRIMARY KEY AUTOINCREMENT,
    Name       TEXT NOT NULL,
    Email      TEXT,
    Region     TEXT NOT NULL DEFAULT 'UNKNOWN',
    IsActive   INTEGER NOT NULL DEFAULT 1,
    CreatedAt  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Orders (
    OrderId        INTEGER PRIMARY KEY AUTOINCREMENT,
    OrderNumber    TEXT NOT NULL UNIQUE,
    CustomerId     INTEGER NOT NULL REFERENCES Customers(CustomerId),
    Status         TEXT NOT NULL DEFAULT 'New'
                   CHECK (Status IN ('New','Picked','Shipped','Cancelled')),
    Amount         NUMERIC NOT NULL DEFAULT 0 CHECK (Amount >= 0),
    OrderDate      TEXT NOT NULL,
    LastModifiedAt TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastModifiedBy TEXT NOT NULL DEFAULT 'seed'
);

CREATE TABLE OrderLines (
    OrderLineId INTEGER PRIMARY KEY AUTOINCREMENT,
    OrderId     INTEGER NOT NULL REFERENCES Orders(OrderId),
    Sku         TEXT NOT NULL,
    Qty         INTEGER NOT NULL CHECK (Qty > 0),
    UnitPrice   NUMERIC NOT NULL CHECK (UnitPrice >= 0),
    -- SQLite generated column, standing in for the PERSISTED computed column.
    LineTotal   NUMERIC GENERATED ALWAYS AS (Qty * UnitPrice) STORED,
    CreatedAt   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE OrderAudit (
    AuditId        INTEGER PRIMARY KEY AUTOINCREMENT,
    OrderId        INTEGER NOT NULL,
    Action         TEXT NOT NULL CHECK (Action IN ('INSERT','UPDATE','DELETE')),
    ChangedColumns TEXT,
    OldValues      TEXT,
    NewValues      TEXT,
    ChangedBy      TEXT NOT NULL,
    AppUser        TEXT,
    HostName       TEXT,
    ProgramName    TEXT,
    SessionId      INTEGER,
    TransactionId  INTEGER,
    ChangedAt      TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- The audit trigger, split into three because SQLite has no multi-event
-- triggers. SQL Server does it in one; see sql/01_schema.sql.
CREATE TRIGGER trg_Orders_Audit_Insert AFTER INSERT ON Orders
BEGIN
    INSERT INTO OrderAudit (OrderId, Action, NewValues, ChangedBy, AppUser)
    VALUES (new.OrderId, 'INSERT',
            json_object('OrderId', new.OrderId, 'OrderNumber', new.OrderNumber,
                        'Status', new.Status, 'Amount', new.Amount),
            'sqlite-dev',
            (SELECT app_user FROM session_context LIMIT 1));
END;

CREATE TRIGGER trg_Orders_Audit_Update AFTER UPDATE ON Orders
BEGIN
    INSERT INTO OrderAudit (OrderId, Action, ChangedColumns, OldValues, NewValues,
                            ChangedBy, AppUser)
    VALUES (new.OrderId, 'UPDATE',
            trim(
                CASE WHEN old.OrderNumber IS NOT new.OrderNumber THEN 'OrderNumber,' ELSE '' END ||
                CASE WHEN old.Status      IS NOT new.Status      THEN 'Status,'      ELSE '' END ||
                CASE WHEN old.Amount      IS NOT new.Amount      THEN 'Amount,'      ELSE '' END ||
                CASE WHEN old.LastModifiedBy IS NOT new.LastModifiedBy THEN 'LastModifiedBy,' ELSE '' END,
                ','),
            json_object('OrderId', old.OrderId, 'OrderNumber', old.OrderNumber,
                        'Status', old.Status, 'Amount', old.Amount),
            json_object('OrderId', new.OrderId, 'OrderNumber', new.OrderNumber,
                        'Status', new.Status, 'Amount', new.Amount),
            'sqlite-dev',
            (SELECT app_user FROM session_context LIMIT 1));
END;

CREATE TRIGGER trg_Orders_Audit_Delete AFTER DELETE ON Orders
BEGIN
    INSERT INTO OrderAudit (OrderId, Action, OldValues, ChangedBy, AppUser)
    VALUES (old.OrderId, 'DELETE',
            json_object('OrderId', old.OrderId, 'OrderNumber', old.OrderNumber,
                        'Status', old.Status, 'Amount', old.Amount),
            'sqlite-dev',
            (SELECT app_user FROM session_context LIMIT 1));
END;

-- Same seed and same planted discrepancies as sql/02_seed.sql.
INSERT INTO Customers (Name, Email, Region) VALUES
    ('Northwind Supply',   'ap@northwind.example',    'EAST'),
    ('Harbour Foods',      'orders@harbour.example',  'EAST'),
    ('Cedar Lane Grocers', 'ap@cedarlane.example',    'WEST'),
    ('Pinebrook Cafe',     'owner@pinebrook.example', 'WEST'),
    ('Lakeside Catering',  'ap@lakeside.example',     'NORTH'),
    ('Dockyard Deli',      NULL,                      'SOUTH');

INSERT INTO Orders (OrderNumber, CustomerId, Status, Amount, OrderDate, LastModifiedBy) VALUES
    ('SO-1001', 1, 'Shipped',   1250.00, '2026-09-28', 'seed'),
    ('SO-1002', 1, 'Shipped',    430.50, '2026-09-29', 'seed'),
    ('SO-1003', 2, 'Picked',    2190.00, '2026-10-01', 'seed'),
    ('SO-1004', 3, 'New',        310.75, '2026-10-03', 'seed'),
    ('SO-1005', 3, 'Shipped',    985.20, '2026-10-05', 'seed'),
    ('SO-1006', 4, 'Cancelled',    0.00, '2026-10-07', 'seed'),
    ('SO-1007', 4, 'Shipped',   1575.00, '2026-10-09', 'seed'),
    ('SO-1008', 5, 'Picked',     640.00, '2026-10-12', 'seed'),
    ('SO-1009', 5, 'New',       3120.40, '2026-10-15', 'seed'),
    ('SO-1010', 6, 'Shipped',    205.00, '2026-10-17', 'seed'),
    ('SO-1011', 2, 'Shipped',    878.25, '2026-10-19', 'seed'),
    ('SO-1012', 1, 'New',       1460.00, '2026-10-21', 'seed');

INSERT INTO OrderLines (OrderId, Sku, Qty, UnitPrice) VALUES
    ( 1, 'FLOUR-25KG',    10,  45.00), ( 1, 'SUGAR-10KG',    20,  40.00),
    ( 2, 'OLIVE-5L',       7,  61.50),
    ( 3, 'COFFEE-1KG',    30,  53.00), ( 3, 'FILTER-100',    20,  30.00),
    ( 4, 'TEA-500G',      15,  20.65), ( 4, 'HONEY-1KG',      1,   1.00),
    ( 5, 'RICE-20KG',     12,  58.10), ( 5, 'LENTIL-10KG',    6,  48.00),
    ( 7, 'BEEF-5KG',      15, 105.00),
    ( 8, 'NAPKIN-CS',     16,  40.00),
    ( 9, 'CHEESE-2KG',    28, 102.00), ( 9, 'BUTTER-5KG',     4,  66.10),
    (10, 'BREAD-TRAY',    10,  20.50),
    (11, 'SALMON-3KG',     5, 125.65), (11, 'LEMON-CS',       5,  50.00),
    (12, 'POTATO-25KG',   20,  73.00);

-- Planted discrepancies (same four as the T-SQL seed).
UPDATE OrderLines SET Qty = Qty - 3 WHERE OrderId = 3 AND Sku = 'FILTER-100';
UPDATE Orders SET Amount = 1557.00, LastModifiedBy = 'CORP\jsmith' WHERE OrderNumber = 'SO-1007';
INSERT INTO OrderLines (OrderId, Sku, Qty, UnitPrice) VALUES (10, 'DELIVERY-FEE', 1, 95.00);
DELETE FROM OrderLines WHERE OrderId = 8;
