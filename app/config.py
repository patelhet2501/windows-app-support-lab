"""Configuration for the OrderDesk lab app.

Nothing secret lives in this file. On the lab VM the connection string comes
from the machine/environment so that IIS app-pool identity changes and
connection-string breakage are observable without editing code.

Resolution order for the connection string:
  1. ORDERDESK_SQL_CONNSTR            (full ODBC connection string)
  2. built from ORDERDESK_SQL_* parts (server/database/trusted/user/password)
  3. the lab default: localhost\\SQLEXPRESS, AppSupportLab, Integrated Security
"""

import os

APP_NAME = "OrderDesk"
LAB_VERSION = "1.0.0"

# "mssql" on the VM, "sqlite" only for the offline dev smoke test.
DB_BACKEND = os.environ.get("ORDERDESK_DB_BACKEND", "mssql").lower()

SQL_SERVER = os.environ.get("ORDERDESK_SQL_SERVER", r"localhost\SQLEXPRESS")
SQL_DATABASE = os.environ.get("ORDERDESK_SQL_DATABASE", "AppSupportLab")
SQL_DRIVER = os.environ.get("ORDERDESK_SQL_DRIVER", "ODBC Driver 18 for SQL Server")
SQL_TRUSTED = os.environ.get("ORDERDESK_SQL_TRUSTED", "yes").lower() in ("yes", "true", "1")
SQL_USER = os.environ.get("ORDERDESK_SQL_USER", "")
SQL_PASSWORD = os.environ.get("ORDERDESK_SQL_PASSWORD", "")
SQL_LOGIN_TIMEOUT = int(os.environ.get("ORDERDESK_SQL_LOGIN_TIMEOUT", "5"))
SQL_ENCRYPT = os.environ.get("ORDERDESK_SQL_ENCRYPT", "yes")
SQL_TRUST_CERT = os.environ.get("ORDERDESK_SQL_TRUST_SERVER_CERT", "yes")

SQLITE_PATH = os.environ.get(
    "ORDERDESK_SQLITE_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev", "orderdesk_smoke.db"),
)


def connection_string() -> str:
    """Return the ODBC connection string, redaction-safe callers use redact()."""
    explicit = os.environ.get("ORDERDESK_SQL_CONNSTR", "").strip()
    if explicit:
        return explicit

    parts = [
        f"Driver={{{SQL_DRIVER}}}",
        f"Server={SQL_SERVER}",
        f"Database={SQL_DATABASE}",
        f"Encrypt={SQL_ENCRYPT}",
        f"TrustServerCertificate={SQL_TRUST_CERT}",
        f"Connection Timeout={SQL_LOGIN_TIMEOUT}",
    ]
    if SQL_TRUSTED:
        parts.append("Trusted_Connection=yes")
    else:
        parts.append(f"UID={SQL_USER}")
        parts.append(f"PWD={SQL_PASSWORD}")
    return ";".join(parts) + ";"


def redact(connstr: str) -> str:
    """Strip password-ish values so a connection string is safe to log or show."""
    safe = []
    for token in connstr.split(";"):
        if not token:
            continue
        key, _, value = token.partition("=")
        if key.strip().lower() in ("pwd", "password"):
            value = "***redacted***"
        safe.append(f"{key}={value}" if _ else key)
    return ";".join(safe) + ";"
