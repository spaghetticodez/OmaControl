#!/bin/sh
# proc-sample.py tests against a fake /proc (OMC_PROC_ROOT) and a fixed clock
# (OMC_CLOCK), so every expected number is exact:
#
#   * ranking is by CPU used since the previous tick, not lifetime average
#   * live CPU % and storage I/O KB/s are computed over the tick interval
#   * a reused PID (new starttime) never inherits the old process's counters
#   * no baseline / a stale baseline falls back to a short live window
#
# Run via tests/run-tests.sh, or directly: ./tests/proc-sample-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

TMPROOT="${TMPDIR:-/tmp}"
T=$(mktemp -d "$TMPROOT/omc-procsample.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

P="$T/proc"
STATE="$T/proc.state"
IO="$T/io.rate"
HZ=$(getconf CLK_TCK)
PAGE=$(getconf PAGESIZE)
mkdir -p "$P"
# 16 GiB of RAM: an rss of 4 GiB is exactly 25.0 %.
echo "MemTotal:       16777216 kB" >"$P/meminfo"

# fake_proc PID COMM UTIME_TICKS STARTTIME RSS_PAGES IO_BYTES
fake_proc() {
  mkdir -p "$P/$1"
  # Fields 3..24 of /proc/<pid>/stat; utime=14, stime=15, starttime=22, rss=24.
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 %s 0 0 0 20 0 1 0 %s 0 %s\n' \
    "$1" "$2" "$3" "$4" "$5" >"$P/$1/stat"
  printf 'rchar: 0\nwchar: 0\nread_bytes: %s\nwrite_bytes: 0\n' "$6" >"$P/$1/io"
}

run() {
  OMC_PROC_ROOT="$P" OMC_CLOCK="$1" python3 "$ROOT/backend/proc-sample.py" "$STATE" "$IO" 20
}

# Tick 1 at t=100: "oldhog" has burned an hour of CPU in the past, "newbusy"
# almost none. Both baselines are recorded.
GIB4=$((4 * 1024 * 1024 * 1024 / PAGE))
fake_proc 100 oldhog $((3600 * HZ)) 10 "$GIB4" 0
fake_proc 200 newbusy 0 5000 1 0
run 100 >/dev/null

# Tick 2 at t=102: oldhog idle, newbusy used one full core for 2 s and read
# 2 MiB.
fake_proc 200 newbusy $((2 * HZ)) 5000 1 2097152
OUT=$(run 102)
check_eq "rank: busy-now beats busy-long-ago" "200" "$(echo "$OUT" | awk 'NR==1{print $1}')"
check_eq "live cpu: one core for the interval = 100.0" "100.0" "$(echo "$OUT" | awk '$1==200{print $2}')"
check_eq "live cpu: idle process = 0.0 (not its lifetime average)" "0.0" "$(echo "$OUT" | awk '$1==100{print $2}')"
check_eq "pmem: 4 GiB of 16 GiB = 25.0" "25.0" "$(echo "$OUT" | awk '$1==100{print $3}')"
check_eq "comm column" "newbusy" "$(echo "$OUT" | awk '$1==200{print $4}')"
check_eq "io: 2 MiB over 2 s = 1024.0 KB/s" "1024.0" "$(awk '$1==200{print $2}' "$IO")"

# Tick 3 at t=104: PID 200 was reused by an unrelated process (new starttime)
# that has used 1 s of CPU since it started. The old process had 2 s; a delta
# against those counters would clamp to 0. A process born inside the interval
# is charged all of its CPU time: 1 s over 2 s = 50.0.
fake_proc 200 reused "$HZ" 9000 1 0
OUT=$(run 104)
check_eq "pid reuse: no delta against the old process's counters" "50.0" "$(echo "$OUT" | awk '$1==200{print $2}')"

# Tick 4 at t=106: a process born since the last tick (not in the baseline)
# that has run flat out for 1.5 s of the 2 s interval is charged 75.0, not 0.
fake_proc 300 newborn $((3 * HZ / 2)) 9500 1 1048576
OUT=$(run 106)
check_eq "new process: charged its CPU since start" "75.0" "$(echo "$OUT" | awk '$1==300{print $2}')"
check_eq "new process: ranks first" "300" "$(echo "$OUT" | awk 'NR==1{print $1}')"
check_eq "new process: io since start = 512.0 KB/s" "512.0" "$(awk '$1==300{print $2}' "$IO")"
rm -rf "$P/300"

# A gap over 30 s (shell closed, suspend) is not averaged over: it re-samples
# a short live window. Static fake counters therefore read 0.
fake_proc 100 oldhog $((3700 * HZ)) 10 "$GIB4" 0
OUT=$(run 500)
check_eq "stale baseline: live re-sample, not a long average" "0.0" "$(echo "$OUT" | awk '$1==100{print $2}')"

# First ever run (no state file) also produces live values, with every row.
rm -f "$STATE"
OUT=$(run 600)
check_eq "no baseline: still lists every process" "2" "$(echo "$OUT" | wc -l | tr -d ' ')"

# State lines are "pid starttime ticks io"; a corrupt file is ignored.
echo "garbage" >"$STATE"
run 700 >/dev/null
check_eq "corrupt state: recovers and rewrites it" "t 700.000" "$(head -1 "$STATE")"

finish
