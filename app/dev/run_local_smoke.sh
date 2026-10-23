#!/usr/bin/env bash
# DEV ONLY. Builds the SQLite smoke database, starts the Flask app against it,
# and exercises every route. Proves the app's own code works before it is
# deployed to the Windows lab VM; proves nothing about IIS or SQL Server.
#
# Usage:  app/dev/run_local_smoke.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
appdir="$(dirname "$here")"
db="$here/orderdesk_smoke.db"
port="${PORT:-5099}"

echo "== building $db"
rm -f "$db"
sqlite3 "$db" < "$here/sqlite_smoke.sql"

echo "== sanity: variances in the smoke database"
sqlite3 -header -column "$db" "
SELECT o.OrderNumber, o.Amount AS Header,
       COALESCE(SUM(l.LineTotal),0) AS Lines,
       o.Amount - COALESCE(SUM(l.LineTotal),0) AS Variance
FROM Orders o LEFT JOIN OrderLines l ON l.OrderId = o.OrderId
GROUP BY o.OrderId HAVING Variance <> 0 ORDER BY o.OrderNumber;"

export ORDERDESK_DB_BACKEND=sqlite
export ORDERDESK_SQLITE_PATH="$db"
export ORDERDESK_LOG_DIR="$here/logs"
export PORT="$port"

echo "== starting app on port $port"
"${PYTHON:-python3}" "$appdir/app.py" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 2.5

base="http://127.0.0.1:$port"
fail=0
check() {  # check <label> <expected-status> <path>
    code=$(curl -s -o /tmp/smoke_body -w '%{http_code}' "$base$3" || echo 000)
    if [ "$code" = "$2" ]; then
        echo "   ok   $1 ($code)"
    else
        echo "   FAIL $1: expected $2, got $code"
        head -c 300 /tmp/smoke_body; echo
        fail=1
    fi
}

check "GET /"               200 "/"
check "GET /orders"         200 "/orders"
check "GET /discrepancies"  200 "/discrepancies"
check "GET /audit"          200 "/audit"
check "GET /health"         200 "/health"
check "GET /diag"           200 "/diag"
check "GET /api/orders"     200 "/api/orders"
check "GET /api/discrepancies" 200 "/api/discrepancies"
check "GET /static/style.css"  200 "/static/style.css"
check "GET /nope"           404 "/nope"

echo "== POST a status change, then confirm the audit trigger fired"
before=$(sqlite3 "$db" "SELECT COUNT(*) FROM OrderAudit;")
curl -s -o /dev/null -X POST -d 'status=Shipped' \
     -H 'X-Lab-User: CORP\tester' "$base/orders/1/status"
after=$(sqlite3 "$db" "SELECT COUNT(*) FROM OrderAudit;")
echo "   audit rows: $before -> $after"
if [ "$after" -le "$before" ]; then echo "   FAIL audit trigger did not fire"; fail=1
else echo "   ok   audit trigger fired"; fi
sqlite3 -header -column "$db" \
  "SELECT AuditId, OrderId, Action, ChangedColumns, AppUser FROM OrderAudit ORDER BY AuditId DESC LIMIT 3;"

echo "== rejecting an invalid status"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'status=Teleported' "$base/orders/1/status")
[ "$code" = "400" ] && echo "   ok   invalid status rejected (400)" \
                    || { echo "   FAIL expected 400, got $code"; fail=1; }

echo "== simulating a database failure (points the app at an unusable path)"
kill $pid; sleep 1
ORDERDESK_SQLITE_PATH="/nonexistent-dir/nope.db" PORT="$port" \
    "${PYTHON:-python3}" "$appdir/app.py" >/dev/null 2>&1 &
pid=$!
sleep 2.5
code=$(curl -s -o /tmp/smoke_body -w '%{http_code}' "$base/health")
echo "   /health returned $code"
[ "$code" = "503" ] && echo "   ok   degraded health reported as 503" \
                    || { echo "   FAIL expected 503, got $code"; fail=1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "$base/orders")
[ "$code" = "503" ] && echo "   ok   /orders returns the db_error page (503)" \
                    || { echo "   FAIL expected 503 on /orders, got $code"; fail=1; }

echo
[ "$fail" = "0" ] && echo "SMOKE TEST PASSED" || { echo "SMOKE TEST FAILED"; exit 1; }
