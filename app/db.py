"""Database access for the OrderDesk lab app.

Two backends:
  mssql  - pyodbc against SQL Server (this is what the lab VM runs)
  sqlite - offline smoke test only, so the app can be exercised without SQL Server

Every failure is wrapped in DbError carrying a short `kind` so the web layer can
show the support-relevant distinction between "SQL is down", "login failed" and
"permission denied" instead of one generic 500.
"""

import re
import time

import config


class DbError(Exception):
    """A database failure classified for support triage."""

    def __init__(self, kind, message, sqlstate=None, native=None):
        super().__init__(message)
        self.kind = kind            # unreachable | login_failed | permission_denied | missing_object | other
        self.message = message
        self.sqlstate = sqlstate
        self.native = native

    def as_dict(self):
        return {
            "kind": self.kind,
            "message": self.message,
            "sqlstate": self.sqlstate,
            "native_error": self.native,
        }


def _classify(exc):
    """Map a pyodbc error onto a support-meaningful kind.

    SQLSTATE and the native SQL Server error number are both checked because the
    four lab failures are told apart by exactly these codes:
      18456 login failed   229/297 permission denied   208 missing object
      08001/08S01 network or instance unreachable
    """
    text = str(exc)
    sqlstate = None
    native = None

    args = getattr(exc, "args", ())
    if args:
        sqlstate = str(args[0])
    m = re.search(r"\((\d+)\)", text)
    if m:
        native = int(m.group(1))

    if native == 18456 or "Login failed for user" in text:
        return DbError("login_failed", "SQL Server rejected the login.", sqlstate, native)
    if native == 18452 or "not associated with a trusted" in text:
        return DbError("login_failed", "SQL Server rejected the login (untrusted domain or no such login).", sqlstate, native)
    if native in (229, 230, 297, 300) or "permission was denied" in text.lower() or "The SELECT permission" in text:
        return DbError("permission_denied", "The app's SQL principal lacks permission on the object.", sqlstate, native)
    if native == 208 or "Invalid object name" in text:
        return DbError("missing_object", "A table or view the app needs does not exist.", sqlstate, native)
    if native == 4060 or "Cannot open database" in text:
        return DbError("login_failed", "The login succeeded but cannot open the requested database.", sqlstate, native)
    if sqlstate in ("08001", "08S01", "HYT00", "HYT01") or "server was not found" in text.lower() \
            or "Named Pipes Provider" in text or "TCP Provider" in text:
        return DbError("unreachable", "Cannot reach the SQL Server instance.", sqlstate, native)
    if "Data source name not found" in text or "IM002" == sqlstate:
        return DbError("other", "The ODBC driver named in the connection string is not installed.", sqlstate, native)
    return DbError("other", text.strip()[:500], sqlstate, native)


# --------------------------------------------------------------------------
# connection handling
# --------------------------------------------------------------------------

def _connect_mssql(app_user):
    try:
        import pyodbc
    except ImportError as exc:  # pragma: no cover - environment problem, not a lab failure
        raise DbError("other", f"pyodbc is not installed: {exc}")

    connstr = config.connection_string()
    try:
        conn = pyodbc.connect(connstr, timeout=config.SQL_LOGIN_TIMEOUT)
    except Exception as exc:
        raise _classify(exc)

    # Hand the end user to SQL Server so the audit trigger records who acted,
    # not just the shared app-pool service account.
    try:
        cur = conn.cursor()
        cur.execute("EXEC sys.sp_set_session_context @key = N'app_user', @value = ?", app_user)
        cur.close()
    except Exception:
        # Session context is a nice-to-have; never fail a request over it.
        pass
    return conn


def _connect_sqlite(app_user):
    import sqlite3

    try:
        conn = sqlite3.connect(config.SQLITE_PATH, timeout=5)
    except Exception as exc:
        raise DbError("unreachable", f"Cannot open {config.SQLITE_PATH}: {exc}")
    conn.execute("PRAGMA foreign_keys = ON")
    # Stands in for SQL Server's sp_set_session_context: the audit triggers
    # read the acting user from here. A real table, not a TEMP one, because
    # the smoke schema's own seed fires those triggers too.
    conn.execute("CREATE TABLE IF NOT EXISTS session_context(app_user TEXT)")
    conn.execute("DELETE FROM session_context")
    try:
        conn.execute("INSERT INTO session_context(app_user) VALUES (?)", (app_user,))
        conn.commit()
    except Exception as exc:
        conn.close()
        raise DbError("unreachable", f"Cannot use {config.SQLITE_PATH}: {exc}")
    return conn


def connect(app_user="anonymous"):
    if config.DB_BACKEND == "sqlite":
        return _connect_sqlite(app_user)
    return _connect_mssql(app_user)


def _qmark(sql):
    """Both backends use ? placeholders, so queries are written once."""
    return sql


def query(sql, params=(), app_user="anonymous"):
    conn = None
    try:
        conn = connect(app_user)
        cur = conn.cursor()
        cur.execute(_qmark(sql), params)
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        return rows
    except DbError:
        raise
    except Exception as exc:
        raise _classify(exc)
    finally:
        if conn is not None:
            conn.close()


def execute(sql, params=(), app_user="anonymous"):
    conn = None
    try:
        conn = connect(app_user)
        cur = conn.cursor()
        cur.execute(_qmark(sql), params)
        affected = cur.rowcount
        conn.commit()
        return affected
    except DbError:
        raise
    except Exception as exc:
        if conn is not None:
            try:
                conn.rollback()
            except Exception:
                pass
        raise _classify(exc)
    finally:
        if conn is not None:
            conn.close()


def ping():
    """Round-trip the database for the health endpoint. Returns (ok, detail, ms)."""
    started = time.perf_counter()
    try:
        rows = query("SELECT 1 AS ok")
        ms = round((time.perf_counter() - started) * 1000, 1)
        return True, {"ok": rows[0]["ok"]}, ms
    except DbError as exc:
        ms = round((time.perf_counter() - started) * 1000, 1)
        return False, exc.as_dict(), ms


# --------------------------------------------------------------------------
# queries the app actually serves
# --------------------------------------------------------------------------

ORDERS_SQL = """
SELECT  o.OrderId,
        o.OrderNumber,
        c.Name            AS CustomerName,
        o.Status,
        o.Amount,
        o.OrderDate,
        o.LastModifiedBy
FROM    app.Orders   AS o
JOIN    app.Customers AS c ON c.CustomerId = o.CustomerId
ORDER BY o.OrderId
"""

ORDERS_SQL_SQLITE = """
SELECT  o.OrderId, o.OrderNumber, c.Name AS CustomerName, o.Status,
        o.Amount, o.OrderDate, o.LastModifiedBy
FROM    Orders o JOIN Customers c ON c.CustomerId = o.CustomerId
ORDER BY o.OrderId
"""

DISCREPANCY_SQL = """
SELECT  o.OrderId,
        o.OrderNumber,
        o.Amount                    AS HeaderAmount,
        COALESCE(SUM(l.LineTotal),0) AS LineTotal,
        o.Amount - COALESCE(SUM(l.LineTotal),0) AS Variance
FROM    app.Orders AS o
LEFT JOIN app.OrderLines AS l ON l.OrderId = o.OrderId
GROUP BY o.OrderId, o.OrderNumber, o.Amount
HAVING  o.Amount <> COALESCE(SUM(l.LineTotal),0)
ORDER BY ABS(o.Amount - COALESCE(SUM(l.LineTotal),0)) DESC
"""

DISCREPANCY_SQL_SQLITE = """
SELECT  o.OrderId, o.OrderNumber, o.Amount AS HeaderAmount,
        COALESCE(SUM(l.LineTotal),0) AS LineTotal,
        o.Amount - COALESCE(SUM(l.LineTotal),0) AS Variance
FROM    Orders o LEFT JOIN OrderLines l ON l.OrderId = o.OrderId
GROUP BY o.OrderId, o.OrderNumber, o.Amount
HAVING o.Amount <> COALESCE(SUM(l.LineTotal),0)
ORDER BY ABS(o.Amount - COALESCE(SUM(l.LineTotal),0)) DESC
"""

AUDIT_SQL = """
SELECT TOP (25) AuditId, OrderId, Action, ChangedColumns, ChangedBy, AppUser, ChangedAt
FROM   audit.OrderAudit
ORDER BY AuditId DESC
"""

AUDIT_SQL_SQLITE = """
SELECT AuditId, OrderId, Action, ChangedColumns, ChangedBy, AppUser, ChangedAt
FROM   OrderAudit ORDER BY AuditId DESC LIMIT 25
"""

UPDATE_STATUS_SQL = """
UPDATE app.Orders
SET    Status = ?, LastModifiedAt = SYSUTCDATETIME(), LastModifiedBy = ?
WHERE  OrderId = ?
"""

UPDATE_STATUS_SQL_SQLITE = """
UPDATE Orders
SET    Status = ?, LastModifiedAt = CURRENT_TIMESTAMP, LastModifiedBy = ?
WHERE  OrderId = ?
"""


def _pick(mssql_sql, sqlite_sql):
    return sqlite_sql if config.DB_BACKEND == "sqlite" else mssql_sql


def list_orders(app_user="anonymous"):
    return query(_pick(ORDERS_SQL, ORDERS_SQL_SQLITE), (), app_user)


def list_discrepancies(app_user="anonymous"):
    return query(_pick(DISCREPANCY_SQL, DISCREPANCY_SQL_SQLITE), (), app_user)


def list_audit(app_user="anonymous"):
    return query(_pick(AUDIT_SQL, AUDIT_SQL_SQLITE), (), app_user)


def set_order_status(order_id, status, app_user="anonymous"):
    return execute(
        _pick(UPDATE_STATUS_SQL, UPDATE_STATUS_SQL_SQLITE),
        (status, app_user, order_id),
        app_user,
    )
