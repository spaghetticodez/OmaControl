#!/bin/sh
# OmaControl data collector — outputs a single JSON blob with system metrics.
# Called via Quickshell Process{} every 2s.
#
# All rate meters (CPU, per-core CPU, disk IO, network) share one 0.2s
# sampling window so the script stays cheap.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
. "$SELF_DIR/schema.sh"
DATA_DIR="$OMCONTROL_DATA_DIR"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
NOW=$(/usr/bin/date +%s)

# Per-tick cost: this runs every 2-5 s for as long as the shell runs, so
# values are read with the shell's own `read` wherever possible and every
# external command is one pass over its input. Values that only change at
# boot (CPU model, kernel, ...) and the parsed GPU dump are cached in the
# run dir.

# Single-collector guard: BarWidget spawns collect.sh every 2s AND the
# omcontrol-collect service runs it on the same cadence. Only one may run
# per tick; the loser exits quietly and BarWidget just reuses its last
# sample (parseCollect("") falls back to the previous payload).
# The braces scope 2>/dev/null to the open: a bare `exec 9>f 2>/dev/null`
# would also redirect the script's own stderr for the rest of the run.
{ exec 9>"$DATA_DIR/.omc_collect.lock"; } 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

# Escape a value for embedding inside a JSON double-quoted string: backslash
# then quote doubling. Control chars are stripped so stray tabs/newlines can
# never break the stdout blob.
esc() {
  printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

NL='
'

# num VALUE -> VALUE without surrounding spaces in _n if it is a plain
# non-negative number, else 0. Values go into the JSON and SQL unquoted.
num() {
  _n=$1
  _n=${_n#"${_n%%[! ]*}"}
  _n=${_n%"${_n##*[! ]}"}
  case "$_n" in '' | .* | *. | *.*.* | *[!0-9.]*) _n=0 ;; esac
}

# rd FILE -> its first line in _v ("" when unreadable), without a fork.
rd() {
  _v=""
  [ -r "$1" ] && IFS= read -r _v <"$1"
  :
}

# --- Toast notifications are fired from sql-ins.py (single choke point),
#     which reads alert_prefs.json itself; nothing here needs the file. ---

# --- Schema repair. backend/schema.sh owns the versioned DDL, the
#     complete-object check (4 tables + 3 indexes) and the v5 metric-column
#     ALTERs; it converges idempotently from any version-marked state and
#     only bumps user_version once the full schema verifies. Abort the tick
#     (exit 1) if the DB cannot be repaired - otherwise the JSON would be
#     built from an incomplete schema. ---
if ! schema_repair "$DB" "$DATA_DIR"; then exit 1; fi

D="$DATA_DIR"
CPU_PRE="$D/.omc_cpu_pre.$$"
CPU_POST="$D/.omc_cpu_post.$$"
DS_PRE="$D/.omc_disk_pre.$$"
DS_POST="$D/.omc_disk_post.$$"
NET_CUR="$D/.omc_net_cur.$$"
DISKIO="$D/.omc_diskio.$$"
PS_FILE="$D/.omc_ps.$$"
PROC_IO_RATE="$D/.omc_proc_io_rate.$$"
PROC_SWAP="$D/.omc_proc_swap.$$"
TMPFILES="$CPU_PRE $CPU_POST $DS_PRE $DS_POST $NET_CUR $DISKIO $PS_FILE $PROC_IO_RATE $PROC_SWAP $DATA_DIR/.cur_names_min.$$ $DATA_DIR/.promote.$$ $DATA_DIR/.seen.$$"
trap 'rm -f -- $TMPFILES' EXIT INT TERM

# --- Tick-to-tick sampling state. Rewritten every tick and meaningless after
#     a reboot, so it lives on tmpfs (/run/user/<uid>) when available instead
#     of wearing the disk; OMCONTROL_RUN_DIR overrides (tests). ---
omc_run_dir
RUN="$OMCONTROL_RUN_DIR"
NET_STATE_NEW="$RUN/net.state.new.$$"
TMPFILES="$TMPFILES $NET_STATE_NEW"

# --- Top 20 processes by live CPU (+ per-process storage I/O rate) ---
# proc-sample.py measures CPU-time deltas since the previous tick, like top.
# ps's pcpu would be a lifetime average (CPU time / process age). pcpu is
# thread-summed and can exceed 100% (300% = 3 cores of work); it is divided
# by the core count (NCORES, counted from /proc/stat below) so every surface
# reports average CPU across cores instead.
python3 "$SELF_DIR/proc-sample.py" "$RUN/proc.state" "$PROC_IO_RATE" 20 >"$PS_FILE" 2>/dev/null
[ -f "$PROC_IO_RATE" ] || : >"$PROC_IO_RATE"

# --- Swap per process (VmSwap in kB) ---
awk '{ f="/proc/"$1"/status"; s=0; while ((getline l < f) > 0) { if (l ~ /^VmSwap:/) { match(l, /^VmSwap: *[0-9]+/); s=substr(l,RLENGTH)+0; break } } close(f); print $1, s }' "$PS_FILE" >"$PROC_SWAP"

# --- CPU + disk counters. Rates are deltas against the previous tick, so
#     they cover the whole poll interval (like the network rate below). With
#     no usable baseline (first run, reboot, or a gap over 30s) fall back to
#     a 0.2s window rather than averaging over the gap. ---
CPU_STAT_AWK='/^cpu /{print "cpu", $5+$6, $2+$3+$4+$5+$6+$7+$8; next}
     /^cpu[0-9]+ /{sub("cpu","",$1); print $1, $5+$6, $2+$3+$4+$5+$6+$7+$8}'
STATE_CPU="$RUN/cpu.state"
STATE_DISK="$RUN/disk.state"
STATE_T="$RUN/sample.t"
T_NOW=$(date +%s%3N 2>/dev/null)
case "$T_NOW" in '' | *[!0-9]*) T_NOW=$((NOW * 1000)) ;; esac
ELAPSED_MS=0
if [ -s "$STATE_CPU" ] && [ -s "$STATE_DISK" ] && [ -s "$STATE_T" ]; then
  T_PREV=$(cat "$STATE_T" 2>/dev/null)
  case "$T_PREV" in '' | *[!0-9]*) T_PREV=0 ;; esac
  ELAPSED_MS=$((T_NOW - T_PREV))
fi
if [ "$ELAPSED_MS" -gt 0 ] && [ "$ELAPSED_MS" -le 30000 ]; then
  CPU_BASE="$STATE_CPU"
  DS_BASE="$STATE_DISK"
else
  awk "$CPU_STAT_AWK" /proc/stat >"$CPU_PRE"
  awk '{print $3, $6, $10}' /proc/diskstats >"$DS_PRE"
  sleep 0.2
  T_PRE=$T_NOW
  T_NOW=$(date +%s%3N 2>/dev/null)
  case "$T_NOW" in '' | *[!0-9]*) T_NOW=$((T_PRE + 200)) ;; esac
  ELAPSED_MS=$((T_NOW - T_PRE))
  [ "$ELAPSED_MS" -gt 0 ] || ELAPSED_MS=200
  CPU_BASE="$CPU_PRE"
  DS_BASE="$DS_PRE"
fi
awk "$CPU_STAT_AWK" /proc/stat >"$CPU_POST"
awk '{print $3, $6, $10}' /proc/diskstats >"$DS_POST"

# --- Disk IO rates (sectors -> KB/s over the elapsed window) ---
awk -v ms="$ELAPSED_MS" 'NR==FNR { r[$1]=$2; w[$1]=$3; next }
  { if (!($1 in r)) { r[$1]=$2; w[$1]=$3; next }
    dr=($2-r[$1])*512/1024*1000/ms; dw=($3-w[$1])*512/1024*1000/ms;
    if (dr<0) dr=0; if (dw<0) dw=0;
    printf "%s %.1f %.1f\n", $1, dr, dw }' "$DS_BASE" "$DS_POST" >"$DISKIO"

# --- Aggregate + per-core CPU, and the core count, in one pass ---
CPU_OUT=$(awk 'NR==FNR { idle[$1]=$2; tot[$1]=$3; next }
  {
    i = $2 - idle[$1]; t = $3 - tot[$1];
    if ($1 == "cpu") { pct = (t > 0) ? sprintf("%.1f", (1 - i / t) * 100) : "0.0"; next }
    n++
    if (t > 0) c = (1 - i / t) * 100; else c = 0;
    cores = cores sprintf("{\"id\":%d,\"pct\":%.1f},", $1, c)
  }
  END { printf "%s %d %s", (pct == "" ? "0.0" : pct), n, cores }' "$CPU_BASE" "$CPU_POST")
CPU_PCT=${CPU_OUT%% *}
CPU_OUT=${CPU_OUT#* }
NCORES=${CPU_OUT%% *}
CORES_LIST=${CPU_OUT#* }
[ "$NCORES" -gt 0 ] 2>/dev/null || NCORES=1
if [ -n "$CORES_LIST" ]; then
  CORES="[${CORES_LIST%,}]"
else
  CORES="[]"
fi

# Keep this tick's counters as the next tick's baseline.
mv -f "$CPU_POST" "$STATE_CPU" 2>/dev/null
mv -f "$DS_POST" "$STATE_DISK" 2>/dev/null
echo "$T_NOW" >"$STATE_T" 2>/dev/null

# --- Load average, CPU frequency, uptime: plain reads, no forks ---
read -r LOAD_1 LOAD_5 LOAD_15 _ </proc/loadavg

CPU_HZ=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
  rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
  case "$_v" in '' | *[!0-9]*) ;; *) CPU_HZ=$((_v / 1000)) ;; esac
fi
if [ -z "$CPU_HZ" ]; then
  CPU_HZ=$(awk 'NR<=32 && $1=="cpu" && $2=="MHz" {printf "%d", $4; exit}' /proc/cpuinfo 2>/dev/null)
fi
CPU_HZ=${CPU_HZ:-0}

read -r _v _ </proc/uptime
UPTIME_S=${_v%%.*}

# --- Memory + swap (one read loop over /proc/meminfo) ---
MEM_TOTAL_KB=0 MEM_AVAIL_KB=0 MEM_FREE_KB=0 MEM_BUFFERS_KB=0 MEM_CACHED_KB=0
SWAP_TOTAL_KB=0 SWAP_FREE_KB=0
while read -r _k _v _; do
  case "$_k" in
    MemTotal:) MEM_TOTAL_KB=$_v ;;
    MemFree:) MEM_FREE_KB=$_v ;;
    MemAvailable:) MEM_AVAIL_KB=$_v ;;
    Buffers:) MEM_BUFFERS_KB=$_v ;;
    Cached:) MEM_CACHED_KB=$_v ;;
    SwapTotal:) SWAP_TOTAL_KB=$_v ;;
    SwapFree:)
      SWAP_FREE_KB=$_v
      break
      ;;
  esac
done </proc/meminfo
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
MEM_USED_MB=$((MEM_USED_KB / 1024))
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_FREE_MB=$((MEM_FREE_KB / 1024))
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
MEM_CACHED_MB=$((MEM_CACHED_KB / 1024))
MEM_BUFFERS_MB=$((MEM_BUFFERS_KB / 1024))
SWAP_TOTAL_MB=$((SWAP_TOTAL_KB / 1024))
SWAP_USED_MB=$(((SWAP_TOTAL_KB - SWAP_FREE_KB) / 1024))

# --- CPU temperature ---
CPU_TEMP=""
# Prefer the CPU package sensor exposed by hwmon (AMD k10temp Tctl, zenpower
# Tdie, Intel coretemp "Package id 0"). Many desktops, AMD in particular,
# expose no /sys/class/thermal zones at all.
for hw in /sys/class/hwmon/hwmon*; do
  [ -n "$CPU_TEMP" ] && break
  rd "$hw/name"
  case "$_v" in
    k10temp | zenpower | coretemp) ;;
    *) continue ;;
  esac
  for lbl in "$hw"/temp*_label; do
    [ -f "$lbl" ] || continue
    rd "$lbl"
    case "$_v" in
      Tctl | Tdie | Package\ id\ 0)
        rd "${lbl%_label}_input"
        if [ -n "$_v" ]; then
          CPU_TEMP=$((_v / 1000))
          break
        fi
        ;;
    esac
  done
done
# Fall back to thermal zones: x86_pkg_temp by its type file, else the first zone.
if [ -z "$CPU_TEMP" ]; then
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    rd "${zone%/temp}/type"
    if [ "$_v" = "x86_pkg_temp" ] || [ -z "$CPU_TEMP" ]; then
      rd "$zone"
      if [ -n "$_v" ]; then
        CPU_TEMP=$((_v / 1000))
      fi
    fi
  done
fi
CPU_TEMP=${CPU_TEMP:-0}

# --- Disk usage (df), per-disk I/O and the totals in one awk pass ---
# btrfs subvolumes and bind mounts repeat one filesystem under several mount
# points with identical numbers: each is reported once, at the first
# (shallowest) mount df lists. LUKS/dm mounts show up as /dev/mapper/<name>
# in df but dm-N in diskstats, so that map is read from sysfs first.
# The "Disk" metric is the total I/O rate across the df-mounted partitions
# (summing those avoids double-counting whole-device + partition entries in
# /proc/diskstats); without any of them in diskstats (rare), physical whole
# devices are summed instead.
DM_MAP=""
for dmn_dev in /sys/class/block/dm-*/dm/name; do
  rd "$dmn_dev"
  [ -n "$_v" ] || continue
  _d=${dmn_dev%/dm/name}
  DM_MAP="$DM_MAP$_v/${_d##*/}
"
done
DISK_OUT=$(df -P 2>/dev/null | OMC_DM_MAP="$DM_MAP" OMC_DISKIO="$DISKIO" awk '
  function esc(s,   o, c, i) {
    gsub(/[\x00-\x1F\x7F]/, "", s); o = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\" || c == "\"") o = o "\\"
      o = o c
    }
    return o
  }
  BEGIN {
    diskio = ENVIRON["OMC_DISKIO"]
    n = split(ENVIRON["OMC_DM_MAP"], lines, "\n")
    for (i = 1; i <= n; i++) if ((p = index(lines[i], "/")) > 1) dm[substr(lines[i], 1, p - 1)] = substr(lines[i], p + 1)
    while ((getline l < diskio) > 0) {
      split(l, f, " "); io[++nio] = f[1]; rr[f[1]] = f[2]; ww[f[1]] = f[3]
    }
    close(diskio)
    max = 0
  }
  $1 == "Filesystem" || NF < 6 { next }
  {
    fs = $1; blk = $2; used = $3
    m = $0
    for (i = 0; i < 5; i++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", m)
    sub(/[ \t]+$/, "", m)
    if (fs in seen) next
    if (fs ~ /^\/dev\/mapper\//) { dev = dm[substr(fs, 13)]; if (dev == "") next }
    else if (fs ~ /^\/dev\//) dev = substr(fs, 6)
    else next
    if (!(blk + 0 > 0) || m !~ /^\//) next
    seen[fs] = 1; want[dev] = 1
    pct = sprintf("%.1f", used * 100 / blk)
    if (int(pct) > max) max = int(pct)
    disks = disks sprintf("{\"dev\":\"%s\",\"mount\":\"%s\",\"size_gb\":%.1f,\"used_gb\":%.1f,\"pct\":%s,\"read_kbs\":%s,\"write_kbs\":%s},",
      esc(dev), esc(m), blk / 1048576, used / 1048576, pct, (dev in rr) ? rr[dev] : 0, (dev in ww) ? ww[dev] : 0)
  }
  END {
    for (i = 1; i <= nio; i++) if (io[i] in want) { r += rr[io[i]]; w += ww[io[i]]; hit = 1 }
    if (!hit) for (i = 1; i <= nio; i++) if (io[i] !~ /^(loop|dm-|ram|zram|sr)/) { r += rr[io[i]]; w += ww[io[i]]; hit = 1 }
    rs = hit ? sprintf("%.1f", r) : "0"; ws = hit ? sprintf("%.1f", w) : "0"
    printf "%d %s %s %.1f %s", max, rs, ws, rs + ws, disks
  }')
DISK_MAX_PCT=${DISK_OUT%% *}
DISK_OUT=${DISK_OUT#* }
DISK_R_TOT=${DISK_OUT%% *}
DISK_OUT=${DISK_OUT#* }
DISK_W_TOT=${DISK_OUT%% *}
DISK_OUT=${DISK_OUT#* }
DISK_IO_TOT=${DISK_OUT%% *}
DISKS=${DISK_OUT#* }
case "$DISK_MAX_PCT" in '' | *[!0-9]*) DISK_MAX_PCT=0 DISK_R_TOT=0 DISK_W_TOT=0 DISK_IO_TOT=0 DISKS="" ;; esac
if [ -n "$DISKS" ]; then
  DISKS="[${DISKS%,}]"
else
  DISKS="[]"
fi

# --- Network rates (KB/s). Mirrors the netspeed bar widget's reading: the
#     delta between this tick and the last is divided by the real elapsed
#     milliseconds, then EMA-smoothed (0.3/0.7) for a steady label. Virtual
#     links (docker/br/veth/bridges) are excluded so wifi/ethernet win. ---
NET_STATE="$RUN/net.state"
NOW_MS=$(date +%s%3N 2>/dev/null || echo ${NOW}000)
[ -f "$NET_STATE" ] || : >"$NET_STATE" # first run: no prior counters, all rates 0

awk 'NR>2 { sub(":","",$1); nm=tolower($1)
      if (nm=="lo" || nm ~ /^docker[0-9]*/ || nm ~ /^br-/ || nm ~ /^virbr[0-9]*/ || nm ~ /^veth/ || nm ~ /^vboxnet[0-9]*/) next
      print nm, $2, $10 }' /proc/net/dev >"$NET_CUR"

NETS=$(awk -v now="$NOW_MS" -v stateout="$NET_STATE_NEW" 'NR==FNR {
      rx[$1]=$2; tx[$1]=$3; order[++n]=$1; next }
    {
      ems = now - $6
      if (ems < 1) ems = 2000
      if ($1 in rx) {
        drx = rx[$1] - $2; if (drx < 0) drx = 0
        dtx = tx[$1] - $3; if (dtx < 0) dtx = 0
        rr = drx * 1000.0 / 1024.0 / ems
        tt = dtx * 1000.0 / 1024.0 / ems
        srx[$1] = 0.3 * rr + 0.7 * $4
        stx[$1] = 0.3 * tt + 0.7 * $5
      }
    }
    END {
      # Cumulative rx/tx bytes across the same real interfaces (history rolls).
      for (i = 1; i <= n; i++) { trx += rx[order[i]]; ttx += tx[order[i]] }
      printf "%.0f %.0f\n", trx, ttx
      for (i = 1; i <= n; i++) {
        nm = order[i]
        if (!(nm in srx)) { srx[nm] = 0; stx[nm] = 0 }
        if (srx[nm] < 0.05) srx[nm] = 0
        if (stx[nm] < 0.05) stx[nm] = 0
        printf "%s %d %d %.2f %.2f %d\n", nm, rx[nm], tx[nm], srx[nm], stx[nm], now > stateout
        printf "{\"iface\":\"%s\",\"rx_kbs\":%.1f,\"tx_kbs\":%.1f},", nm, srx[nm], stx[nm]
      }
    }' "$NET_CUR" "$NET_STATE")

mv "$NET_STATE_NEW" "$NET_STATE"
# First line: the cumulative totals; the rest: the per-interface JSON.
NET_TOT_RX=${NETS%%[!0-9]*}
NETS=${NETS#"$NET_TOT_RX"}
NETS=${NETS# }
NET_TOT_TX=${NETS%%[!0-9]*}
NETS=${NETS#"$NET_TOT_TX"}
NETS=${NETS#?}
[ -z "$NET_TOT_RX" ] && NET_TOT_RX=0
[ -z "$NET_TOT_TX" ] && NET_TOT_TX=0
if [ -n "$NETS" ]; then
  NETS="[${NETS%,}]"
else
  NETS="[]"
fi

# --- GPU (nvidia-smi) ---
GPU_PCT="0"
GPU_MEM="0"
GPU_MEM_TOTAL="0"
GPU_TEMP="0"
GPU_POWER="0"
GPU_FAN="0"
GPU_CLOCK="0"
GPU_NAME=""
GPU_DRIVER=""
GPU_POWER_MAX="0"
GPU_MEM_CLOCK="0"
GPU_GRAPHICS_CLOCK="0"
GPU_LINK_GEN=""
GPU_LINK_GEN_MAX=""
GPU_LINK_WIDTH=""
GPU_LINK_WIDTH_MAX=""
GPU_BUS=""
GPU_ENC="0"
GPU_DEC="0"
GPU_MEM_CLOCK_MAX="0"
# OMC_NVIDIA_SMI lets tests point at a stub binary; production keeps the
# default nvidia-smi resolved through the hardened PATH. The AMD sysfs
# fallback below remains the standby when neither produces a value.
NVIDIA_SMI="${OMC_NVIDIA_SMI:-nvidia-smi}"
# Per-process GPU memory (pid used_mib), from the cached XML dump; /dev/null
# when there is none (no NVIDIA, unloaded driver, ...).
GPU_PROC_MAP=/dev/null
if command -v "$NVIDIA_SMI" >/dev/null 2>&1; then
  GPU_LINE=$(timeout 10 "$NVIDIA_SMI" --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed,clocks.sm,utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null)
  # Last GPU's line; every field must be a plain number ("[N/A]",
  # "[Not Supported]" and the like read as 0, so they can't break the JSON).
  GPU_LINE=${GPU_LINE##*"$NL"}
  if [ -n "$GPU_LINE" ]; then
    set -f
    OLDIFS=$IFS
    IFS=,
    # shellcheck disable=SC2086 # split on commas on purpose
    set -- $GPU_LINE
    IFS=$OLDIFS
    set +f
    num "${1:-}"
    GPU_PCT=$_n
    num "${2:-}"
    GPU_MEM=$_n
    num "${3:-}"
    GPU_MEM_TOTAL=$_n
    num "${4:-}"
    GPU_TEMP=$_n
    num "${5:-}"
    GPU_POWER=$_n
    num "${6:-}"
    GPU_FAN=$_n
    num "${7:-}"
    GPU_CLOCK=$_n
    num "${8:-}"
    GPU_ENC=$_n
    num "${9:-}"
    GPU_DEC=$_n
    # Tiered cadence: the utilization query above runs every tick; the full
    # -q -x dump (identity, clocks, link, the per-process table) is
    # expensive, so it is refreshed at most once a minute and parsed once
    # per refresh into gpu.info / gpu.procs.
    GPUXML="$RUN/gpu.xml"
    GPUINFO="$RUN/gpu.info"
    rd "$RUN/gpu.t"
    case "$_v" in '' | *[!0-9]*) _v=0 ;; esac
    if [ ! -s "$GPUXML" ] || [ $((NOW - _v)) -gt 60 ]; then
      GPUXML_TMP="$RUN/gpu.xml.tmp.$$"
      TMPFILES="$TMPFILES $GPUXML_TMP"
      timeout 10 "$NVIDIA_SMI" -q -x 2>/dev/null >"$GPUXML_TMP"
      if [ -s "$GPUXML_TMP" ]; then
        mv "$GPUXML_TMP" "$GPUXML"
        echo "$NOW" >"$RUN/gpu.t"
        rm -f "$GPUINFO"
      fi
    fi
    if [ -s "$GPUXML" ] && [ ! -s "$GPUINFO" ]; then
      # One line per field, JSON-escaped; numbers default to 0. Each field
      # is the first occurrence in the dump, like the per-field sed it
      # replaces. Clocks: current from <clocks>, max from <max_clocks>.
      OMC_PROCS="$RUN/gpu.procs.tmp.$$" awk '
        function esc(s,   o, c, i) {
          gsub(/[\x00-\x1F\x7F]/, "", s); o = ""
          for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\" || c == "\"") o = o "\\"
            o = o c
          }
          return o
        }
        # first(KEY, TAG, VALUE_RE, TAIL): value right after the first <TAG>,
        # kept only when it is followed by the literal TAIL.
        function first(k, t, re, tail,   s, p) {
          if ((k in seen) || (p = index($0, "<" t ">")) == 0) return
          seen[k] = 1
          s = substr($0, p + length(t) + 2)
          if (match(s, "^" re) && substr(s, RLENGTH + 1, length(tail)) == tail)
            v[k] = substr(s, 1, RLENGTH)
        }
        function clk(k,   s) {
          if (k in v) return
          s = $0; gsub(/[^0-9]/, "", s); v[k] = s
        }
        BEGIN { procs = ENVIRON["OMC_PROCS"]; printf "" > procs }
        {
          first("name", "product_name", "[^<]*", "</product_name>")
          first("driver", "driver_version", "[^<]*", "</driver_version>")
          first("pmax", "max_power_limit", "[0-9.]*", "")
          first("gen", "current_link_gen", "[0-9]*", "")
          first("genmax", "max_link_gen", "[0-9]*", "")
          first("width", "current_link_width", "[0-9]*", "x")
          first("widthmax", "max_link_width", "[0-9]*", "x")
          first("bus", "pci_bus_id", "00000000:[0-9a-f]*:[0-9a-f]*\\.[0-9]*", "</pci_bus_id>")
        }
        /<clocks>/ { sec = "cur" }
        /<max_clocks>/ { sec = "max" }
        /<min_clocks>/ { sec = "min" }
        /<\/clocks>/ || /<\/max_clocks>/ || /<\/min_clocks>/ { sec = ""; next }
        sec == "cur" && /<mem_clock>/ { clk("mclk") }
        sec == "max" && /<mem_clock>/ { clk("mclkmax") }
        sec == "max" && /<graphics_clock>/ { clk("gclkmax") }
        /<process_info>/ { inproc = 1 }
        inproc && /<pid>/ { s = $0; gsub(/[^0-9]/, "", s); pid = s }
        inproc && /<used_memory>/ {
          s = $0; gsub(/[^0-9]/, "", s)
          if (pid != "") print pid, s > procs
          inproc = 0
        }
        END {
          if (v["pmax"] !~ /^[0-9]+(\.[0-9]+)?$/) v["pmax"] = 0
          if ("bus" in v) v["bus"] = "0000:" substr(v["bus"], 10)
          print esc(v["name"]); print esc(v["driver"]); print v["pmax"]
          print v["gen"]; print v["genmax"]; print v["width"]; print v["widthmax"]
          print v["bus"]; print v["mclk"] + 0; print v["mclkmax"] + 0; print v["gclkmax"] + 0
        }' "$GPUXML" >"$GPUINFO.tmp.$$" &&
        mv "$GPUINFO.tmp.$$" "$GPUINFO" && mv "$RUN/gpu.procs.tmp.$$" "$RUN/gpu.procs"
      rm -f "$GPUINFO.tmp.$$" "$RUN/gpu.procs.tmp.$$"
    fi
    if [ -s "$GPUINFO" ]; then
      {
        IFS= read -r GPU_NAME
        IFS= read -r GPU_DRIVER
        read -r GPU_POWER_MAX
        read -r GPU_LINK_GEN
        read -r GPU_LINK_GEN_MAX
        read -r GPU_LINK_WIDTH
        read -r GPU_LINK_WIDTH_MAX
        read -r GPU_BUS
        read -r GPU_MEM_CLOCK
        read -r GPU_MEM_CLOCK_MAX
        read -r GPU_GRAPHICS_CLOCK
      } <"$GPUINFO"
      # GPU_ENC stays the utilization.encoder percentage from the query
      # above; <session_count> is a session count, not a load figure.
      [ -s "$RUN/gpu.procs" ] && GPU_PROC_MAP="$RUN/gpu.procs"
    fi
  fi
fi

# --- GPU: AMD fallback (amdgpu sysfs) when nvidia-smi is absent or empty.
#     gpu_busy_percent + vram counters live under /sys/class/drm/card*/device,
#     temperature under the matching hwmon chip. ---
if [ -z "$GPU_NAME" ]; then
  for ADEV in /sys/class/drm/card*/device; do
    [ -r "$ADEV/gpu_busy_percent" ] || continue
    rd "$ADEV/gpu_busy_percent"
    num "$_v"
    GPU_PCT=$_n
    GPU_NAME="AMD GPU"
    GPU_DRIVER="amdgpu"
    if [ -r "$ADEV/mem_info_vram_used" ]; then
      rd "$ADEV/mem_info_vram_used"
      [ -n "$_v" ] || _v=0
      GPU_MEM=$((_v / 1048576))
    fi
    if [ -r "$ADEV/mem_info_vram_total" ]; then
      rd "$ADEV/mem_info_vram_total"
      [ -n "$_v" ] || _v=0
      GPU_MEM_TOTAL=$((_v / 1048576))
    fi
    for hw in /sys/class/hwmon/hwmon*; do
      rd "$hw/name"
      [ "$_v" = "amdgpu" ] || continue
      rd "$hw/temp1_input"
      [ -n "$_v" ] && GPU_TEMP=$((_v / 1000))
      break
    done
    break
  done
fi

# --- CPU + system identity. Fixed until a reboot (the run dir is tmpfs) or
#     a hostname change, so it is gathered and JSON-escaped once and cached.
rd /proc/sys/kernel/hostname
HOST=$_v
rd /proc/sys/kernel/osrelease
KERNEL=$_v
IDENT="$RUN/identity"
IDENT_KEY="$HOST|$KERNEL"
IDENT_OK=""
if [ -s "$IDENT" ]; then
  {
    IFS= read -r _k
    IFS= read -r CPU_NAME
    read -r CPU_THREADS
    read -r CPU_CORES
    read -r CPU_MAX_MHZ
    IFS= read -r HOST_J
    IFS= read -r KERNEL_J
    IFS= read -r OS_PRETTY
  } <"$IDENT"
  [ "$_k" = "$IDENT_KEY" ] && IDENT_OK=1
fi
if [ -z "$IDENT_OK" ]; then
  CPU_NAME=$(sed -n 's/^model name[[:space:]]*: *//p' /proc/cpuinfo | head -1 | tr -d '\r')
  CPU_THREADS=$(grep -m1 '^siblings' /proc/cpuinfo | awk '{print $3}' 2>/dev/null)
  CPU_CORES=$(grep -m1 '^cpu cores' /proc/cpuinfo | awk '{print $4}' 2>/dev/null)
  rd /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
  num "$_v"
  CPU_MAX_MHZ=$((${_n%%.*} / 1000))
  num "$CPU_THREADS"
  CPU_THREADS=${_n%%.*}
  num "$CPU_CORES"
  CPU_CORES=${_n%%.*}
  OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
  CPU_NAME=$(esc "$CPU_NAME")
  HOST_J=$(esc "$HOST")
  KERNEL_J=$(esc "$KERNEL")
  OS_PRETTY=$(esc "$OS_PRETTY")
  printf '%s\n' "$IDENT_KEY" "$CPU_NAME" "$CPU_THREADS" "$CPU_CORES" "$CPU_MAX_MHZ" \
    "$HOST_J" "$KERNEL_J" "$OS_PRETTY" >"$IDENT" 2>/dev/null
fi

# --- Battery (fields read from uevent, no forks without a battery) ---
BAT_PRESENT=0
BAT_PCT=0
BAT_STATUS=""
BAT_POWER_W=0
BAT_MODEL=""
for f in /sys/class/power_supply/BAT*/uevent; do
  [ -r "$f" ] || continue
  BAT_PRESENT=1
  BAT_POWER=""
  while IFS='=' read -r _k _v; do
    case "$_k" in
      POWER_SUPPLY_CAPACITY) BAT_PCT=$_v ;;
      POWER_SUPPLY_STATUS) BAT_STATUS=$_v ;;
      POWER_SUPPLY_POWER_NOW) BAT_POWER=$_v ;;
      POWER_SUPPLY_MODEL_NAME) BAT_MODEL=$_v ;;
    esac
  done <"$f"
  case "$BAT_PCT" in '' | *[!0-9]*) BAT_PCT=0 ;; esac
  case "$BAT_POWER" in
    '' | *[!0-9]*) ;;
    *) BAT_POWER_W=$(awk "BEGIN{printf \"%.1f\", $BAT_POWER/1000000}") ;;
  esac
  BAT_STATUS=$(esc "$BAT_STATUS")
  BAT_MODEL=$(esc "$BAT_MODEL")
  break
done

# --- Process count ---
set -- /proc/[0-9]*
PROC_COUNT=$#

# --- Per-process disk I/O rate (KB/s) comes from proc-sample.py above. ---

PROCS=$(awk '
  FILENAME == gpumap { gpu[$1]=$2; next }
  FILENAME == swapmap { swap[$1]=$2; next }
  FILENAME == ratemap { rate[$1]=$2; next }
  {
    gsub(/[<>\x00-\x1F\x7F"\\]/, " ", $4)
    c = (ncores > 0) ? $2 / ncores : $2
    g = ($1 in gpu) ? gpu[$1] : 0
    gpct = (g > 0 && gpu_total > 0) ? g * 100 / gpu_total : 0
    swm = ($1 in swap) ? swap[$1] / 1024 : 0
    ior = ($1 in rate) ? rate[$1] : 0
    printf "{\"pid\":%s,\"cpu\":%.2f,\"mem\":%s,\"swap\":%.1f,\"io_kbs\":%.1f,\"gpu_mem\":%.0f,\"gpu\":%.1f,\"name\":\"%s\"}%s",
      $1, c, $3, swm, ior, g, gpct, $4, (++n < 20 ? "," : "")
  }' gpumap="$GPU_PROC_MAP" swapmap="$PROC_SWAP" ratemap="$PROC_IO_RATE" \
  gpu_total="$GPU_MEM_TOTAL" ncores="$NCORES" "$GPU_PROC_MAP" "$PROC_SWAP" "$PROC_IO_RATE" "$PS_FILE")

# --- Persist sample, prune old data, and record metric spikes all in ONE
#     sqlite3 call (was 5 separate invocations per tick). ---
SQL="INSERT OR REPLACE INTO metrics (ts, cpu_pct, mem_used_mb, mem_total_mb, gpu_pct, gpu_temp, cpu_temp, proc_count, disk_pct, disk_io, disk_r, disk_w, net_rx_bytes, net_tx_bytes) VALUES ($NOW, $CPU_PCT, $MEM_USED_MB, $MEM_TOTAL_MB, $GPU_PCT, $GPU_TEMP, $CPU_TEMP, $PROC_COUNT, $DISK_MAX_PCT, $DISK_IO_TOT, $DISK_R_TOT, $DISK_W_TOT, $NET_TOT_RX, $NET_TOT_TX);
DELETE FROM metrics WHERE ts < $NOW - 604800;
DELETE FROM proc_history WHERE ts < $NOW - 86400;
DELETE FROM events WHERE ts < $NOW - 1209600;"

# Metric-spike events (persistent log for the Events tab).
SPC=$(printf "%d" "${CPU_PCT%.*}" 2>/dev/null)
[ -z "$SPC" ] && SPC=0
if [ "$SPC" -ge 95 ]; then
  SQL="$SQL
INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'cpu_spike', '', '', 'CPU peaked at $CPU_PCT%')
  WHERE NOT EXISTS (SELECT 1 FROM events WHERE type='cpu_spike' AND ts > $NOW - 30);"
fi
SMM=$((MEM_TOTAL_KB > 0 ? (MEM_TOTAL_KB - MEM_AVAIL_KB) * 100 / MEM_TOTAL_KB : 0))
if [ "$SMM" -ge 92 ]; then
  SQL="$SQL
INSERT INTO events (ts, type, app, publisher, msg) VALUES ($NOW, 'mem_spike', '', '', 'Memory peaked at $SMM%')
  WHERE NOT EXISTS (SELECT 1 FROM events WHERE type='mem_spike' AND ts > $NOW - 30);"
fi
sqlite3 -cmd ".timeout 1500" "$DB" <<SQL 2>/dev/null
$SQL
SQL

# --- Persist per-process snapshot once per minute (chart drill-down) + refresh
#     app metadata (publisher/verified/desc; cached in app_meta) ---
PROC_MIN=$((NOW / 60))
rd "$DATA_DIR/.omc_proc_min"
case "$_v" in '' | *[!0-9]*) _v=0 ;; esac
if [ "$PROC_MIN" -gt "$_v" ]; then
  PROC_TS=$((PROC_MIN * 60))
  # Prune stale temp files from past invocations that got killed mid-run.
  find "$DATA_DIR" -maxdepth 1 -mmin +30 \
    \( -name '.omc_*' -o -name '.cur_names.*' -o -name '.cur_names_min.*' \
    -o -name '.new_names.*' -o -name '.promote.*' -o -name '.fresh.*' \
    -o -name '.seen.*' \) -delete 2>/dev/null
  PER_PROC_NET="1"
  if [ -f "$DATA_DIR/metrics_prefs.json" ] &&
    grep -q '"perProcNet"[[:space:]]*:[[:space:]]*\(false\|0\)' "$DATA_DIR/metrics_prefs.json" 2>/dev/null; then
    PER_PROC_NET="0"
  fi
  # Per-process network KB/s for this minute (ss-based, like the netspeed
  # widget). Merged into the snapshot so the chart drill-down can show who
  # drove a network spike; bandwidth-only pids are appended to the CPU list.
  # Disabled via the "per-process network" toggle (metrics_prefs.json): the
  # ss dump is skipped and entries keep no nr/nt fields (the UI then hides
  # the per-proc net column entirely instead of showing zeroes).
  NETPROCS_FILE="$D/.omc_netprocs.$$"
  TMPFILES="$TMPFILES $NETPROCS_FILE"
  if [ "$PER_PROC_NET" = "1" ]; then
    OMCONTROL_DATA_DIR="$DATA_DIR" python3 "$SELF_DIR/net-procs.py" >"$NETPROCS_FILE" 2>/dev/null
  else
    : >"$NETPROCS_FILE"
  fi
  PROC_JSON=$(
    PROCS_RAW="$PROCS" OMC_NETPROCS="$NETPROCS_FILE" python3 - <<'PY'
import json, os, sys
raw = os.environ.get("PROCS_RAW", "").strip()
net = []
try:
    net = json.load(open(os.environ["OMC_NETPROCS"]))
except Exception:
    net = []
try:
    procs = json.loads("[" + raw + "]") if raw else []
except Exception:
    procs = []
if not net:
    print(json.dumps(procs))
    sys.exit()
netmap = {}
for e in net:
    netmap[str(e.get("pid"))] = e
pidset = set()
for p in procs:
    pid = str(p.get("pid", ""))
    n = netmap.get(pid)
    p["nr"] = float(n.get("rx", 0)) if n else 0.0
    p["nt"] = float(n.get("tx", 0)) if n else 0.0
    pidset.add(pid)
appended = 0
for e in net:
    if str(e.get("pid")) in pidset:
        continue
    procs.append({"pid": int(e.get("pid") or 0), "cpu": 0.0, "mem": 0.0,
                  "swap": 0.0, "io_kbs": 0.0, "gpu_mem": 0.0, "gpu": 0.0,
                  "name": e.get("name") or str(e.get("pid") or "?"),
                  "nr": float(e.get("rx", 0) or 0), "nt": float(e.get("tx", 0) or 0)})
    appended += 1
    if appended >= 20:
        break
print(json.dumps(procs))
PY
  )
  PROC_JSON_SQL=$(echo "$PROC_JSON" | sed "s/'/''/g")
  sqlite3 -cmd ".timeout 1500" "$DB" "INSERT OR REPLACE INTO proc_history VALUES ($PROC_TS, '$PROC_JSON_SQL');" 2>/dev/null
  awk '{print $1, $4}' "$PS_FILE" | OMCONTROL_DB="$DB" python3 "$SELF_DIR/app-meta.py" 2>/dev/null
  # App-exit events: names in last minute's snapshot that are gone now
  # (only "real" apps: resolved to a package/core, never ephemeral shells
  # or churning kernel worker threads).
  ps -eo comm --no-headers 2>/dev/null | sed 's/[[:space:]]*$//' |
    grep -vE '^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|logout|timeout|omcontrol-poll|sd_notify|kworker.*|kthreadd|ksoftirqd|kswapd|kcompactd|khugepaged|kblockd|kdevtmpfs|khelper|writeback|jbd2|kcryptd|dmcrypt_write|oom_reaper|migration|watchdog|cpuhp|rcu|scsi_|usb_|irq/|ata_|xfs-|btrfs-|flush-|events_unbound|netns|kauditd|\[.*\]|systemd-udevd)$' |
    sort -u >"$DATA_DIR/.cur_names_min.$$"
  if [ -f "$DATA_DIR/.last_names_min" ]; then
    # Both lists are sort -u output under LC_ALL=C, so comm finds the exits
    # in one pass instead of one grep per name.
    # sql-ins.py (a python start) only runs when something actually exited.
    EXITS=$(comm -23 "$DATA_DIR/.last_names_min" "$DATA_DIR/.cur_names_min.$$" |
      awk -v ts="$PROC_TS" '{ sub(/\r+$/, "") } NF { printf "event\t%s\tapp_exit\t%s\t\tApp closed: %s\t1\n", ts, $0, $0 }')
    [ -n "$EXITS" ] && printf '%s\n' "$EXITS" | OMCONTROL_DB="$DB" python3 "$SELF_DIR/sql-ins.py" 2>/dev/null
  fi
  mv "$DATA_DIR/.cur_names_min.$$" "$DATA_DIR/.last_names_min"
  echo "$PROC_MIN" >"$DATA_DIR/.omc_proc_min"
fi

# --- Downsampled history rolls moved out of the collector: collect.sh runs on
#     a 2s tick and its history_1h/6h/24h were only consumed by the deleted
#     Panel.qml. The app window now recomputes its own rolls at 30s intervals
#     via sample-json.sh (cached on disk), so nothing here queries the table.

# --- New-app detection ---
# A name is a candidate the first tick it is seen and becomes a new app the
# next tick it is still running (so one-shot helpers don't count). Set
# lookups in awk replace the sort/comm passes over the seen and candidate
# lists, and the seen list is only rewritten when something was promoted.
SEEN_FILE="$DATA_DIR/apps_seen"
CAND_FILE="$DATA_DIR/apps_cand"
NEWAPPS_LOG="$DATA_DIR/new_apps.log"
: >>"$SEEN_FILE"
: >>"$CAND_FILE"
: >>"$NEWAPPS_LOG"
PROMOTE="$DATA_DIR/.promote.$$"

# Userspace processes only: kernel threads are kthreadd (pid 2) and its
# children, zombies have no cmdline. One ps call, no per-process forks.
ps -eo pid=,ppid=,stat=,comm= 2>/dev/null | awk '
  {
    pid = $1; ppid = $2; st = $3
    name = $0
    sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", name)
    sub(/[ \t]+$/, "", name)
  }
  name == "" || pid == 2 || ppid == 2 || st ~ /^Z/ || name ~ /^\[.*\]$/ { next }
  name ~ /^(sh|bash|zsh|dash|fish|ps|pgrep|grep|awk|sed|sleep|cat|head|tail|true|false|tee|sort|uniq|comm|notify-send|omarchy-notification-send|xargs|find|rm|cp|mv|mkdir|dirname|basename|timeout|kworker.*|kthreadd|ksoftirqd|kswapd|kcompactd|khugepaged|kblockd|kdevtmpfs|khelper|writeback|jbd2|kcryptd|dmcrypt_write|oom_reaper|migration|watchdog|cpuhp|rcu|scsi_|usb_|irq\/|ata_|xfs-|btrfs-|flush-|events_unbound|netns|kauditd|systemd-udevd)$/ { next }
  { print name }' | sort -u | OMC_SEEN="$SEEN_FILE" OMC_CAND="$CAND_FILE" OMC_PROMOTE="$PROMOTE" awk '
  BEGIN {
    seenf = ENVIRON["OMC_SEEN"]; candf = ENVIRON["OMC_CAND"]; promote = ENVIRON["OMC_PROMOTE"]
    while ((getline l < seenf) > 0) seen[l] = 1
    close(seenf)
    while ((getline l < candf) > 0) cand[l] = 1
    close(candf)
    printf "" > promote
  }
  !($0 in seen) { if ($0 in cand) print > promote; else fresh[++n] = $0 }
  END {
    printf "" > candf
    for (i = 1; i <= n; i++) print fresh[i] > candf
  }'

NEW_APPS="[]"
if [ -s "$PROMOTE" ]; then
  NEW_APPS=$(OMC_LOG="$NEWAPPS_LOG" awk -v now="$NOW" '
    BEGIN { logf = ENVIRON["OMC_LOG"] }
    { sub(/\r+$/, "") }
    $0 != "" {
      print now " " $0 >> logf
      n = $0; gsub(/["\\]/, " ", n)
      printf "%s{\"name\":\"%s\",\"first_seen\":%s}", sep, n, now; sep = ","
    }' "$PROMOTE")
  NEW_APPS="[$NEW_APPS]"

  # Classify each first-seen launch via the app-meta cache: verified apps are
  # plain launches, known-but-unverified are unsigned_launch, anything without
  # a resolved publisher is an unknown_app — the Security bucket / chart pins.
  OMCONTROL_NOW="$NOW" python3 - "$DB" "$PROMOTE" <<'PY' |
\
import os, sqlite3, sys
db = sys.argv[1]
now = int(os.environ.get("OMCONTROL_NOW") or 0)
names = []
for ln in open(sys.argv[2], encoding="utf-8", errors="replace"):
    nm = ln.rstrip("\n\r")
    if nm.strip():
        names.append(nm)
if not names:
    sys.exit()
con = sqlite3.connect(db, timeout=3)
try:
    for nm in names:
        row = con.execute("SELECT publisher, verified FROM app_meta WHERE name=?", (nm,)).fetchone()
        if row is None or row[0] in ("", "Unknown"):
            typ, known = "unknown_app", "0"
        elif int(row[1] or 0):
            typ, known = "app_launch", "1"
        else:
            typ, known = "unsigned_launch", "1"
        print("event\t%s\t%s\t%s\t\tApp started: %s\t%s" % (now, typ, nm, nm, known))
finally:
    con.close()
PY
    OMCONTROL_DB="$DB" python3 "$SELF_DIR/sql-ins.py" 2>/dev/null
  cat "$PROMOTE" >>"$SEEN_FILE"
  sort -u "$SEEN_FILE" | tail -4000 >"$DATA_DIR/.seen.$$" && mv "$DATA_DIR/.seen.$$" "$SEEN_FILE"
fi

RECENT_APPS=$(tail -5 "$NEWAPPS_LOG" | awk '{gsub(/["\\]/, " ", $2); printf "%s{\"name\":\"%s\",\"ts\":%s}", sep, $2, $1; sep = ","}')
[ -n "$RECENT_APPS" ] && RECENT_APPS="[$RECENT_APPS]" || RECENT_APPS="[]"

# --- Active alert thresholds (profile + resolved limits), fed to the bar the
#     same way sample-json.sh feeds the app window, so the bar bell and the
#     collector's sustained alerts always use the same numbers.
PREFS="${OMCONTROL_ALERT_PREFS:-$DATA_DIR/alert_prefs.json}"
# The resolved thresholds are a pure function of the prefs file and the two
# resolver scripts, so cache them on tmpfs keyed by those files' content
# instead of starting python every tick.
TH_CACHE="$RUN/thresholds.cache"
TH_KEY=$(cat "$PREFS" "$SELF_DIR/omc-thresholds.py" "$SELF_DIR/omc_prefs.py" 2>/dev/null | cksum)
THRESHOLDS_OUT=""
if [ -s "$TH_CACHE" ]; then
  {
    IFS= read -r TH_CACHED_KEY
    IFS= read -r TH_L1
    IFS= read -r TH_L2
  } <"$TH_CACHE"
  [ "$TH_CACHED_KEY" = "$TH_KEY" ] && [ -n "$TH_L1" ] && [ -n "$TH_L2" ] && THRESHOLDS_OUT=1
fi
if [ -z "$THRESHOLDS_OUT" ]; then
  THRESHOLDS_OUT=$(OMC_BACKEND="$SELF_DIR" python3 "$SELF_DIR/omc-thresholds.py" "$PREFS" 2>/dev/null || true)
  [ -n "$THRESHOLDS_OUT" ] && printf '%s\n%s\n' "$TH_KEY" "$THRESHOLDS_OUT" >"$TH_CACHE" 2>/dev/null
  TH_L1=${THRESHOLDS_OUT%%"$NL"*}
  TH_L2=${THRESHOLDS_OUT#*"$NL"}
  TH_L2=${TH_L2%%"$NL"*}
  [ "$TH_L2" = "$THRESHOLDS_OUT" ] && TH_L2=""
fi
ALERT_PROFILE=$TH_L1
THRESHOLDS_JSON=$TH_L2
[ -n "$ALERT_PROFILE" ] || ALERT_PROFILE=medium
[ -n "$THRESHOLDS_JSON" ] || THRESHOLDS_JSON='{}'

# Prunes and metric-spike events are folded into the single sqlite3 call above.

# --- Output JSON ---
# Capped as a last resort: a malfunctioning producer must never be able to
# retain unbounded output in the long-lived shell. 262 KB is far above the
# ~10 KB this blob realistically reaches.
/usr/bin/head -c "${OMCONTROL_MAX_OUT_BYTES:-1048576}" 2>/dev/null <<ENDJSON
{
  "cpu_pct": $CPU_PCT,
  "cores": $CORES,
  "load_1": $LOAD_1,
  "load_5": $LOAD_5,
  "load_15": $LOAD_15,
  "cpu_hz_mhz": $CPU_HZ,
  "cpu_max_mhz": $CPU_MAX_MHZ,
  "cpu_threads": ${CPU_THREADS:-0},
  "cpu_cores": ${CPU_CORES:-0},
  "cpu_name": "$CPU_NAME",
  "uptime_s": $UPTIME_S,
  "mem_used_mb": $MEM_USED_MB,
  "mem_total_mb": $MEM_TOTAL_MB,
  "mem_avail_mb": $MEM_AVAIL_MB,
  "mem_free_mb": $MEM_FREE_MB,
  "mem_cached_mb": $MEM_CACHED_MB,
  "mem_buffers_mb": $MEM_BUFFERS_MB,
  "swap_total_mb": $SWAP_TOTAL_MB,
  "swap_used_mb": $SWAP_USED_MB,
  "cpu_temp": $CPU_TEMP,
  "disk_pct": $DISK_MAX_PCT,
  "disk_io": $DISK_IO_TOT,
  "disk_r": $DISK_R_TOT,
  "disk_w": $DISK_W_TOT,
  "disks": $DISKS,
  "nets": $NETS,
  "gpu_pct": $GPU_PCT,
  "gpu_mem_mb": $GPU_MEM,
  "gpu_mem_total_mb": $GPU_MEM_TOTAL,
  "gpu_temp": $GPU_TEMP,
  "gpu_power_w": $GPU_POWER,
  "gpu_power_max_w": $GPU_POWER_MAX,
  "gpu_fan_pct": $GPU_FAN,
  "gpu_clock_mhz": $GPU_CLOCK,
  "gpu_mem_clock_mhz": $GPU_MEM_CLOCK,
  "gpu_graphics_max_mhz": $GPU_GRAPHICS_CLOCK,
  "gpu_name": "$GPU_NAME",
  "gpu_driver": "$GPU_DRIVER",
  "gpu_link_gen": "$GPU_LINK_GEN",
  "gpu_link_gen_max": "$GPU_LINK_GEN_MAX",
  "gpu_link_width": "$GPU_LINK_WIDTH",
  "gpu_link_width_max": "$GPU_LINK_WIDTH_MAX",
  "gpu_bus": "$GPU_BUS",
  "gpu_enc_pct": $GPU_ENC,
  "gpu_dec_pct": $GPU_DEC,
  "gpu_mem_clock_max_mhz": $GPU_MEM_CLOCK_MAX,
  "battery": {
    "present": $BAT_PRESENT,
    "percent": $BAT_PCT,
    "status": "$BAT_STATUS",
    "power_w": $BAT_POWER_W,
    "model": "$BAT_MODEL"
  },
  "host": "$HOST_J",
  "kernel": "$KERNEL_J",
  "os_pretty": "$OS_PRETTY",
  "proc_count": $PROC_COUNT,
  "ts": $NOW,
  "processes": [$PROCS],
  "new_apps": $NEW_APPS,
  "recent_apps": $RECENT_APPS,
  "alert_profile": "$ALERT_PROFILE",
  "alert_thresholds": $THRESHOLDS_JSON
}
ENDJSON
