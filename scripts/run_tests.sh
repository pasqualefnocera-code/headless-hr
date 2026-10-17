#!/usr/bin/env bash
# Runs the database tests against a throwaway PostgreSQL cluster.
# Nothing persists: the cluster lives in a temp dir and is deleted on exit.
#
# Needs PostgreSQL 16+ server binaries (initdb, pg_ctl, psql). Point PG_BIN at
# the folder that contains them if they are not on your PATH, e.g.
#   PG_BIN=/usr/lib/postgresql/16/bin ./scripts/run_tests.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_BIN="${PG_BIN:-}"
if [[ -n "$PG_BIN" ]]; then export PATH="$PG_BIN:$PATH"; fi

for tool in initdb pg_ctl psql; do
    command -v "$tool" >/dev/null || { echo "missing $tool; set PG_BIN" >&2; exit 1; }
done

# initdb refuses to run as root, so hand off to an unprivileged user if needed.
if [[ "$(id -u)" -eq 0 ]]; then
    RUN_AS="${RUN_AS_USER:-postgres}"
    id "$RUN_AS" >/dev/null 2>&1 || { echo "running as root and user '$RUN_AS' does not exist" >&2; exit 1; }
    exec su "$RUN_AS" -s /bin/bash -c "PATH='$PATH' '${BASH_SOURCE[0]}'"
fi

WORK="$(mktemp -d)"
PORT="${PGTEST_PORT:-54329}"
cleanup() { pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

initdb -D "$WORK/data" -A trust -U postgres >/dev/null
pg_ctl -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -w -l "$WORK/log" start >/dev/null

PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -c "CREATE DATABASE hhr_test"
PSQL+=(-d hhr_test)

echo "== PostgreSQL: $("${PSQL[@]}" -tAc 'show server_version')"
"${PSQL[@]}" -f "$REPO_ROOT/db/schema.sql"
"${PSQL[@]}" -f "$REPO_ROOT/db/tests/test_bitemporal.sql" 2>&1
