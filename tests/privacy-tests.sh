#!/bin/sh
# privacy.sh microphone detection, against a stub pactl (OMC_PACTL) that
# prints real PipeWire `pactl list source-outputs` / `list short sources`
# output, in an isolated data directory:
#
#   * a capture from a real input source is reported with its pid and name
#   * speaker-monitor captures (stream.capture.sink, or a *.monitor source)
#     are not reported as microphone use
#   * the name falls back to application.process.binary
#   * hostile names cannot break the JSON or the state file
#   * a new capture logs exactly one privacy "start" event
#
# Run via tests/run-tests.sh, or directly: ./tests/privacy-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-privacy.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

export OMCONTROL_DATA_DIR="$T"
export OMCONTROL_DB="$T/history.db"
export OMC_PACTL="$T/pactl"
FIXTURE="$T/source-outputs.txt"
: >"$FIXTURE"

# Stub: `list source-outputs` prints the fixture, `list short sources` the
# source table of this machine's layout (86 is a sink monitor, 89 a mic).
cat >"$OMC_PACTL" <<STUB
#!/bin/sh
case "\$*" in
  "list source-outputs") cat "$FIXTURE" ;;
  "list short sources")
    printf '86\talsa_output.usb-Generic.HiFi__Speaker__sink.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n'
    printf '89\talsa_input.usb-Generic.HiFi__Mic__source\tPipeWire\ts24le 2ch 48000Hz\tRUNNING\n'
    ;;
esac
STUB
chmod +x "$OMC_PACTL"

# stream ID SOURCE NAME BINARY CAPTURE_SINK -> one PipeWire source output
stream() {
  printf 'Source Output #%s\n\tDriver: PipeWire\n\tClient: 1\n\tSource: %s\n' "$1" "$2"
  printf '\tCorked: no\n\tProperties:\n\t\tclient.api = "pipewire-pulse"\n'
  [ -n "$3" ] && printf '\t\tapplication.name = "%s"\n' "$3"
  printf '\t\tmedia.name = "Recording"\n\t\tapplication.process.id = "%s"\n' "$((4000 + $1))"
  [ -n "$4" ] && printf '\t\tapplication.process.binary = "%s"\n' "$4"
  [ "$5" = 1 ] && printf '\t\tstream.capture.sink = "true"\n'
  printf '\t\tmedia.class = "Stream/Input/Audio"\n\n'
}

run() { run_interp "$ROOT/backend/privacy.sh" 2>/dev/null; }
devices() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s:%s:%s" % (x["device"], x["pid"], x["name"]) for x in d["devices"]))'
}

# Run 1 seeds the state (no captures yet).
run >/dev/null

# Run 2: a mic capture, a monitor capture flagged by PipeWire, a capture from
# the monitor source without the flag, and one with only a binary name.
{
  stream 1 89 "Firefox" "firefox" 0
  stream 2 86 "OBS" "obs" 1
  stream 3 86 "Visualizer" "cava" 0
  stream 4 89 "" "arecord" 0
} >"$FIXTURE"
OUT=$(run)
check_eq "mic: real capture reported, monitor captures ignored" \
  "microphone:4001:Firefox microphone:4004:arecord" "$(printf '%s' "$OUT" | devices)"
check_eq "mic: one start event per new capture" "2" \
  "$(sqlite3 "$OMCONTROL_DB" "SELECT count(*) FROM privacy_events WHERE action='start' AND device='microphone';")"

# Run 3: unchanged captures log nothing new.
run >/dev/null
check_eq "mic: no duplicate start events" "2" \
  "$(sqlite3 "$OMCONTROL_DB" "SELECT count(*) FROM privacy_events WHERE action='start';")"

# Run 4: a hostile name (quote, backslash, pipe) still yields valid JSON.
stream 5 89 'Ev"il\|App' "" 0 >"$FIXTURE"
OUT=$(run)
check_eq "mic: hostile name sanitized, JSON still parses" \
  "microphone:4005:EvilApp" "$(printf '%s' "$OUT" | devices)"

# Run 5: captures gone -> stop events, empty device list.
: >"$FIXTURE"
OUT=$(run)
check_eq "mic: no captures, no devices" "" "$(printf '%s' "$OUT" | devices)"
check_eq "mic: stop events logged" "3" \
  "$(sqlite3 "$OMCONTROL_DB" "SELECT count(*) FROM privacy_events WHERE action='stop';")"

finish
