#!/bin/sh
# unread.sh (the bar bell) in an isolated data and run directory:
#
#   * unread events and privacy starts count only for enabled sensitivities
#   * the answer is cached in the run dir and served from it while the
#     inputs are unchanged (no python start)
#   * each input invalidates the cache: marking events read, the last-read
#     mark for privacy rows, and the prefs
#
# Run via tests/run-tests.sh, or directly: ./tests/unread-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-unread.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

export OMCONTROL_DATA_DIR="$T"
export OMCONTROL_DB="$T/history.db"
export OMCONTROL_RUN_DIR="$T/run"
export OMCONTROL_ALERT_PREFS="$T/alert_prefs.json"

sqlite3 "$OMCONTROL_DB" "
CREATE TABLE events (id INTEGER PRIMARY KEY, ts INTEGER, type TEXT, app TEXT, publisher TEXT, msg TEXT, read INTEGER DEFAULT 0);
CREATE TABLE privacy_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, action TEXT, device TEXT, name TEXT, pid INTEGER);
INSERT INTO events (ts, type, app, msg) VALUES (100, 'app_launch', 'a', 'x'), (101, 'app_launch', 'b', 'y');
INSERT INTO privacy_events (ts, action, device, name, pid) VALUES (200, 'start', 'microphone', 'rec', 1);"
echo '{"enabled": true, "types": {"New App Launch": "notify", "Mic or Cam Access": "notify"}}' >"$OMCONTROL_ALERT_PREFS"

run() { run_interp "$ROOT/backend/unread.sh" 2>/dev/null; }

check_eq "unread: events and privacy starts counted, privacy color wins" \
  '{"count": 3, "color": "danger"}' "$(run)"
if [ -s "$OMCONTROL_RUN_DIR/unread.cache" ]; then ok "unread: answer cached in the run dir"; else fail "unread: answer cached in the run dir"; fi

# Unchanged inputs are served from the cache: plant a marker answer under
# the current key and expect it back.
KEY=$(sed -n 1p "$OMCONTROL_RUN_DIR/unread.cache")
printf '%s\n%s\n' "$KEY" '{"count": 99, "color": "dim"}' >"$OMCONTROL_RUN_DIR/unread.cache"
check_eq "unread: unchanged inputs served from the cache" '{"count": 99, "color": "dim"}' "$(run)"

sqlite3 "$OMCONTROL_DB" "UPDATE events SET read=1 WHERE app='a';"
check_eq "unread: marking an event read invalidates the cache" \
  '{"count": 2, "color": "danger"}' "$(run)"

echo 300 >"$T/events_lastread_ts"
check_eq "unread: last-read mark hides older privacy rows" \
  '{"count": 1, "color": "green"}' "$(run)"

echo '{"enabled": true, "types": {"New App Launch": "none"}}' >"$OMCONTROL_ALERT_PREFS"
check_eq "unread: a prefs change invalidates the cache" \
  '{"count": 0, "color": "dim"}' "$(run)"

finish
