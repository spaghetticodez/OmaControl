#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl privacy monitor — checks for active webcam/mic/location usage.
# Logs start/stop events into an append-only history for the Privacy tab.
# Outputs JSON: {"devices":[...], "events":[...]}

DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
STATE="$DATA_DIR/privacy_state.json"
LOG="$DATA_DIR/privacy_events.log"
NOW=$(date +%s)

# --- Ensure DB + events table exist ---
# --- Collect current access entries: one per line "device|pid|name" ---
TMP=$(mktemp)
: >"$TMP"

# Webcam via fuser; ${device}:/dev/video*
for dev in /dev/video0 /dev/video1 /dev/video2; do
  if [ -c "$dev" ]; then
    PIDS=$(fuser "$dev" 2>/dev/null | tr -s ' ')
    if [ -n "$PIDS" ]; then
      for pid in $PIDS; do
        pid=$(echo "$pid" | tr -d ' ')
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
          NAME=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
          NAME=${NAME:-unknown}
          echo "camera|$pid|$NAME" >>"$TMP"
        fi
      done
    fi
  fi
done

# Microphone via pactl (active capture streams). The real OS pid lives in
# application.process.id (a Client: line is only a PulseAudio client index).
# PipeWire's pactl prints properties as `application.name = "x"`; the older
# `Application name:` form is still accepted. Captures of a speaker monitor
# (screen recorders, visualizers) are not microphone use: they are marked
# stream.capture.sink = "true" or record from a *.monitor source.
# OMC_PACTL lets tests point at a stub; production resolves pactl on the
# hardened PATH.
PACTL="${OMC_PACTL:-pactl}"
SO=$("$PACTL" list source-outputs 2>/dev/null)
if [ -n "$SO" ]; then
  "$PACTL" list short sources 2>/dev/null | awk -F'\t' '$2 ~ /\.monitor$/ { print $1 }' >"$TMP.mon"
  printf '%s\n' "$SO" | awk -v monfile="$TMP.mon" '
    function prop(line) { sub(/^[^=]*= "/, "", line); sub(/"[ \t]*$/, "", line); return line }
    function flush(n) {
      if (pid ~ /^[0-9]+$/ && !monitor && !(src != "" && src in mon)) {
        n = (name != "") ? name : bin
        gsub(/[|"\\\x00-\x1F\x7F]/, "", n)
        if (n == "") n = "unknown"
        printf "microphone|%s|%s\n", pid, n
      }
      pid = ""; name = ""; bin = ""; src = ""; monitor = 0
    }
    BEGIN { while ((getline l < monfile) > 0) mon[l] = 1; close(monfile) }
    /^Source Output #/ { flush(); next }
    /^[ \t]*Source: / { src = $2; next }
    /application\.process\.id = / { pid = prop($0); next }
    /application\.name = / { name = prop($0); next }
    /application\.process\.binary = / { bin = prop($0); next }
    /stream\.capture\.sink = "true"/ { monitor = 1; next }
    tolower($0) ~ /^[ \t]*application name:/ { sub(/^[^:]*: */, ""); gsub(/"/, ""); name = $0; next }
    END { flush() }
  ' >>"$TMP"
  rm -f "$TMP.mon"
fi

# Location service
if systemctl --user is-active geoclue-agent >/dev/null 2>&1; then
  GEO=$(gdbus call --session --dest org.freedesktop.GeoClue2 --object-path /org/freedesktop/GeoClue2/Manager --method org.freedesktop.GeoClue2.Manager.GetClient 2>/dev/null)
fi
if [ -n "$GEO" ]; then
  echo "location|0|geoclue-agent" >>"$TMP"
fi

# --- Diff against previous state to log start/stop events. Runs every
#     tick, so: one awk for the diff, and sql-ins.py (a python start) and the
#     state rewrite only when something actually changed. ---
sort -u "$TMP" >"$TMP.sorted"
if [ ! -f "$STATE" ]; then
  # First run: seed state, don't log spurious "start" for pre-existing access
  mv -f "$TMP.sorted" "$STATE"
else
  CHANGES=$(OMC_PREV="$STATE" awk -F'|' -v now="$NOW" '
    FILENAME == ENVIRON["OMC_PREV"] { prev[$0] = 1; order[++n] = $0; next }
    { cur[$0] = 1; if (!($0 in prev)) printf "privacy\t%s\tstart\t%s\t%s\t%s\n", now, $1, $3, $2 }
    END {
      for (i = 1; i <= n; i++) {
        l = order[i]
        if (l in cur || l in done) continue
        done[l] = 1
        split(l, f, "|")
        printf "privacy\t%s\tstop\t%s\t%s\t%s\n", now, f[1], f[3], f[2]
      }
    }' "$STATE" "$TMP.sorted")
  if [ -n "$CHANGES" ]; then
    # Bound parameters via the single writer (names were sed-quoted before).
    printf '%s\n' "$CHANGES" | OMCONTROL_DB="$DB" python3 "$SELF_DIR/sql-ins.py" 2>/dev/null
    mv -f "$TMP.sorted" "$STATE"
  fi
fi
rm -f "$TMP" "$TMP.sorted"

# --- Build JSON output (names stripped of quotes, backslashes and control
#     characters so an app name can never break the document) ---
DEVICES=$(awk -F'|' '$1 != "" && $2 ~ /^[0-9]+$/ {
  d = $1; n = $3
  gsub(/["\\\x00-\x1F\x7F]/, "", d); gsub(/["\\\x00-\x1F\x7F]/, "", n)
  printf "%s{\"pid\":%s,\"device\":\"%s\",\"name\":\"%s\"}", sep, $2, d, n; sep = ","
}' "$STATE")

# The table is created here too (one sqlite3 call): sql-ins.py only runs
# when there is something to write.
EVENTS=$(sqlite3 -cmd ".timeout 1500" "$DB" "CREATE TABLE IF NOT EXISTS privacy_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER,
  action TEXT,
  device TEXT,
  name TEXT,
  pid INTEGER
); CREATE INDEX IF NOT EXISTS idx_priv_ts ON privacy_events(ts);
  SELECT '[' || group_concat(json_object('ts', ts, 'action', action, 'device', device, 'name', name, 'pid', pid)) || ']'
  FROM (SELECT ts, action, device, name, pid FROM privacy_events ORDER BY id DESC LIMIT 30);
" 2>/dev/null)
[ -z "$EVENTS" ] && EVENTS="[]"

cat <<ENDJSON
{"devices":[$DEVICES], "events":$EVENTS}
ENDJSON
