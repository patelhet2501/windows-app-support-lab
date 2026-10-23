"""OrderDesk - the sample app for the Windows Server app-support lab.

Hosted on IIS through HttpPlatformHandler: IIS owns the port, hands this
process a PORT, and proxies to it. Run directly for local development.

The routes exist to make support work observable:
  /                      landing page with live dependency status
  /orders                the app's real screen (reads SQL)
  /discrepancies         header-vs-lines variance, the data-discrepancy scenario
  /audit                 recent rows written by the audit trigger
  /health                JSON health probe used by the PowerShell health check
  /diag                  app pool identity, connection string (redacted), env
"""

import datetime as dt
import getpass
import logging
import os
import platform
import socket
import sys

from flask import Flask, jsonify, redirect, render_template, request, url_for

import config
import db

LOG_DIR = os.environ.get(
    "ORDERDESK_LOG_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"),
)
try:
    os.makedirs(LOG_DIR, exist_ok=True)
    _log_handlers = [
        logging.FileHandler(os.path.join(LOG_DIR, "orderdesk.log"), encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ]
except OSError:
    # A locked-down app-pool identity may not be able to write here; that is
    # itself one of the lab failures, so fall back to stdout and keep serving.
    _log_handlers = [logging.StreamHandler(sys.stdout)]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    handlers=_log_handlers,
)
log = logging.getLogger("orderdesk")

app = Flask(__name__)
STARTED_AT = dt.datetime.now(dt.timezone.utc)


def current_user():
    """Who IIS says is calling; falls back to a header for lab convenience."""
    return (
        request.headers.get("X-Lab-User")
        or request.remote_user
        or request.environ.get("REMOTE_USER")
        or "anonymous"
    )


def process_identity():
    """The account the worker process runs as - the app-pool identity on IIS."""
    try:
        return getpass.getuser()
    except Exception:
        return os.environ.get("USERNAME") or os.environ.get("USER") or "unknown"


@app.context_processor
def inject_globals():
    return {
        "app_name": config.APP_NAME,
        "lab_version": config.LAB_VERSION,
        "now": dt.datetime.now(dt.timezone.utc),
    }


@app.errorhandler(db.DbError)
def handle_db_error(exc):
    """Render the failure with its runbook, instead of a bare 500."""
    runbooks = {
        "login_failed": ("01-bad-service-account-password.md",
                         "The app pool identity or SQL login is being rejected."),
        "permission_denied": ("04-permission-denied.md",
                              "The login works but lacks rights on the object."),
        "unreachable": ("03-bad-connection-string.md",
                        "The server/instance in the connection string cannot be reached."),
        "missing_object": ("03-bad-connection-string.md",
                           "Connected, but to a database that does not have the app's schema."),
        "other": ("03-bad-connection-string.md", "Unclassified database failure."),
    }
    runbook, hint = runbooks.get(exc.kind, runbooks["other"])
    log.error("DbError kind=%s sqlstate=%s native=%s msg=%s",
              exc.kind, exc.sqlstate, exc.native, exc.message)
    payload = {
        "error": "database_unavailable",
        "kind": exc.kind,
        "message": exc.message,
        "sqlstate": exc.sqlstate,
        "native_error": exc.native,
        "runbook": runbook,
        "hint": hint,
        "connection": config.redact(config.connection_string()),
    }
    if request.path.startswith("/api/") or request.path == "/health":
        return jsonify(payload), 503
    return render_template("db_error.html", **payload), 503


@app.route("/")
def index():
    ok, detail, ms = db.ping()
    return render_template(
        "index.html",
        db_ok=ok,
        db_detail=detail,
        db_ms=ms,
        identity=process_identity(),
        connection=config.redact(config.connection_string()),
        backend=config.DB_BACKEND,
    )


@app.route("/orders")
def orders():
    rows = db.list_orders(current_user())
    return render_template("orders.html", orders=rows, user=current_user())


@app.route("/orders/<int:order_id>/status", methods=["POST"])
def update_status(order_id):
    status = (request.form.get("status") or "").strip()
    if status not in ("New", "Picked", "Shipped", "Cancelled"):
        return render_template("orders.html",
                               orders=db.list_orders(current_user()),
                               user=current_user(),
                               error=f"Rejected status '{status}'."), 400
    changed = db.set_order_status(order_id, status, current_user())
    log.info("order %s status -> %s by %s (%s row(s))", order_id, status, current_user(), changed)
    return redirect(url_for("orders"))


@app.route("/discrepancies")
def discrepancies():
    rows = db.list_discrepancies(current_user())
    return render_template("discrepancies.html", rows=rows)


@app.route("/audit")
def audit():
    rows = db.list_audit(current_user())
    return render_template("audit.html", rows=rows)


@app.route("/api/orders")
def api_orders():
    return jsonify(db.list_orders(current_user()))


@app.route("/api/discrepancies")
def api_discrepancies():
    return jsonify(db.list_discrepancies(current_user()))


@app.route("/health")
def health():
    """Liveness + dependency check. 200 healthy, 503 degraded.

    Invoke-LabHealthCheck.ps1 parses this, so the shape is a contract.
    """
    ok, detail, ms = db.ping()
    body = {
        "app": config.APP_NAME,
        "version": config.LAB_VERSION,
        "status": "healthy" if ok else "degraded",
        "host": socket.gethostname(),
        "identity": process_identity(),
        "pid": os.getpid(),
        "python": platform.python_version(),
        "started_utc": STARTED_AT.isoformat(),
        "uptime_seconds": round((dt.datetime.now(dt.timezone.utc) - STARTED_AT).total_seconds(), 1),
        "checks": {
            "database": {
                "ok": ok,
                "latency_ms": ms,
                "backend": config.DB_BACKEND,
                "server": config.SQL_SERVER,
                "database": config.SQL_DATABASE,
                "detail": detail,
            }
        },
    }
    return jsonify(body), (200 if ok else 503)


@app.route("/diag")
def diag():
    """Support-facing detail. Read-only, and the password is never echoed."""
    interesting = {k: v for k, v in os.environ.items() if k.startswith("ORDERDESK_")}
    if "ORDERDESK_SQL_PASSWORD" in interesting:
        interesting["ORDERDESK_SQL_PASSWORD"] = "***redacted***"
    if "ORDERDESK_SQL_CONNSTR" in interesting:
        interesting["ORDERDESK_SQL_CONNSTR"] = config.redact(interesting["ORDERDESK_SQL_CONNSTR"])
    return jsonify({
        "identity": process_identity(),
        "host": socket.gethostname(),
        "cwd": os.getcwd(),
        "python": sys.executable,
        "connection_string": config.redact(config.connection_string()),
        "log_dir": LOG_DIR,
        "environment": interesting,
    })


if __name__ == "__main__":
    # HttpPlatformHandler sets %HTTP_PLATFORM_PORT%; honour it when present.
    port = int(os.environ.get("HTTP_PLATFORM_PORT") or os.environ.get("PORT") or 5000)
    log.info("starting %s on port %s as %s (backend=%s)",
             config.APP_NAME, port, process_identity(), config.DB_BACKEND)
    app.run(host="127.0.0.1", port=port, debug=False)
