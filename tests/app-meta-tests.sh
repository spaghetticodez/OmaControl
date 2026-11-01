#!/bin/sh
# app-meta.py privacy tests, in an isolated data directory.
#
#   * safe_command() keeps the program (and an interpreter's script/module)
#     but never arguments, inline code or chromium-style joined argv
#   * an unpackaged process with a secret in argv is recorded without it
#   * legacy raw-argv descriptions are purged (secure_delete + checkpoint)
#     while sanitized and packaged rows are left alone
#
# Run via tests/run-tests.sh, or directly: ./tests/app-meta-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-appmeta.XXXXXX")
TOOL_PID=""
cleanup() {
  [ -n "$TOOL_PID" ] && {
    pkill -P "$TOOL_PID" 2>/dev/null
    kill "$TOOL_PID" 2>/dev/null
  }
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

export OMCONTROL_DB="$T/history.db"
q() { sqlite3 -cmd ".timeout 1500" "$OMCONTROL_DB" "$1" 2>/dev/null; }

# --- safe_command unit cases ---
python3 - "$ROOT/backend/app-meta.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("app_meta", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cases = [
    (["/usr/bin/curl", "-u", "me:hunter2", "https://x"], "curl"),
    (["/opt/tool/bin/tool", "--token=SECRET"], "tool"),
    (["python3", "/home/u/bin/sync.py", "--api-key", "SECRET"], "python3 sync.py"),
    (["python3", "-u", "-m", "http.server", "8000"], "python3 -m http.server"),
    (["python3", "-c", "print('SECRET')"], "python3"),
    (["bash", "-c", "curl -H 'Authorization: SECRET' x"], "bash"),
    (["node", "--max-old-space-size=4096", "/srv/app/server.js", "SECRET"], "node server.js"),
    (["perl", "-e", "print SECRET"], "perl"),
    (["/opt/brave/brave --type=renderer --secret=SECRET"], "brave"),
    ([], ""),
]
bad = [(a, want, m.safe_command(a)) for a, want in cases if m.safe_command(a) != want]
for a, want, got in bad:
    print("  # safe_command(%r) = %r, want %r" % (a, got, want))
sys.exit(1 if bad else 0)
PY
check_eq "safe_command: program/script only, never arguments" "0" "$?"

# --- end to end: an unpackaged process with a secret on its command line ---
cp "$(command -v sh)" "$T/omc-secret-tool"
"$T/omc-secret-tool" -c 'sleep 30; :' omc --password=SECRET_TOKEN_42 2>/dev/null &
TOOL_PID=$!
sleep 0.3
printf '%s omc-secret-tool\n' "$TOOL_PID" | python3 "$ROOT/backend/app-meta.py" 2>/dev/null
DESC=$(q "SELECT desc FROM app_meta WHERE name='omc-secret-tool';")
case "$DESC" in
  *SECRET*) fail "app-meta: secret argv not stored" "desc=$DESC" ;;
  *) ok "app-meta: secret argv not stored" ;;
esac
case "$DESC" in
  *"Program: omc-secret-tool"*) ok "app-meta: program name still identifies the process" ;;
  *) fail "app-meta: program name still identifies the process" "desc=$DESC" ;;
esac
pkill -P "$TOOL_PID" 2>/dev/null
kill "$TOOL_PID" 2>/dev/null
TOOL_PID=""

# --- legacy purge ---
q "INSERT OR REPLACE INTO app_meta (name, exe, pkg, publisher, desc, verified, source, first_seen, updated) VALUES
  ('legacy-a', '', '', 'Unknown', 'Command: /opt/a --token=LEGACY_SECRET_1', 0, 'unknown', 1, 1),
  ('legacy-b', '', '', 'Unknown', 'Unknown system process · /opt/b -p LEGACY_SECRET_2', 0, 'unknown', 1, 1),
  ('modern', '', '', 'Unknown', 'Unknown system process · Program: modern', 0, 'unknown', 1, 99),
  ('packaged', '/usr/bin/p', 'p', 'Arch', 'Tool · with a dot', 1, 'pacman', 1, 99);"
python3 "$ROOT/backend/app-meta.py" </dev/null 2>/dev/null
check_eq "purge: legacy Command: row blanked" "" "$(q "SELECT desc FROM app_meta WHERE name='legacy-a';")"
check_eq "purge: legacy '· argv' row blanked" "" "$(q "SELECT desc FROM app_meta WHERE name='legacy-b';")"
check_eq "purge: legacy rows marked for re-resolution" "0|0" \
  "$(q "SELECT group_concat(updated, '|') FROM app_meta WHERE name IN ('legacy-a','legacy-b');")"
check_eq "purge: sanitized row untouched" "Unknown system process · Program: modern" \
  "$(q "SELECT desc FROM app_meta WHERE name='modern';")"
check_eq "purge: packaged row untouched" "Tool · with a dot" \
  "$(q "SELECT desc FROM app_meta WHERE name='packaged';")"
LEFT=$(cat "$OMCONTROL_DB" "$OMCONTROL_DB-wal" 2>/dev/null | grep -ac 'LEGACY_SECRET')
check_eq "purge: no legacy secret bytes left in db/wal" "0" "$LEFT"

finish
