#!/bin/sh
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/bootstrap.sh"
# OmaControl enforcement engine — reads rules.json and enforces persistent rules.
# Usage: enforce.sh [--dry-run] [--apps]
#   kind=app,     action=disable -> kill any matching process (kill-on-launch)
#   kind=service, action=disable -> systemctl --user mask the unit (persistent)
#   (legacy kill rules are honoured as well)
#   --apps: kill-on-launch only (the bar runs this every tick). Service masks
#           are persistent and left alone, and it exits at once when no rule
#           is enabled.
# Names in protected-names (compositor, shell, audio, bus, ...) are never
# matched; a rule naming one is reported as an error instead.

RULES_FILE="${OMCONTROL_RULES:-$HOME/.local/share/omcontrol/rules.json}"
DATA_DIR="${OMCONTROL_DATA_DIR:-$HOME/.local/share/omcontrol}"
DB="${OMCONTROL_DB:-$DATA_DIR/history.db}"
DRY_RUN=""
APPS_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --apps) APPS_ONLY=1 ;;
  esac
done

if [ ! -f "$RULES_FILE" ]; then
  echo '{"killed":[],"errors":[]}'
  exit 0
fi
# Per-tick fast path: nothing enabled, nothing to do (a full run still has to
# unmask services whose rule was switched off, so this is --apps only).
if [ -n "$APPS_ONLY" ] && ! grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$RULES_FILE" 2>/dev/null; then
  echo '{"killed":[],"errors":[]}'
  exit 0
fi
NOW=$(date +%s)

# Reject anything that isn't a plain user unit name: no absolute/relative paths,
# no leading dot, no whitespace or shell metacharacters, no glob patterns, and
# only the character set systemd allows in unit names ([A-Za-z0-9_.@:-]), ending
# in ".service". A JIT'd rule string is never worth trusting systemctl to parse.
valid_unit() {
  case "$1" in
    *.service) ;;
    *) return 1 ;;
  esac
  case "$1" in
    .*) return 1 ;;
    */*) return 1 ;;
    *[!A-Za-z0-9_.@:-]*) return 1 ;;
  esac
  return 0
}

# Mask/unmask only ever run after valid_unit() — a persisted rule must be a
# legitimate unit name before it can affect the systemd user manager.
mask_unit() {
  valid_unit "$1" || return 1
  systemctl --user mask "$1" >/dev/null 2>&1
  systemctl --user stop "$1" >/dev/null 2>&1
}
unmask_unit() {
  valid_unit "$1" || return 1
  systemctl --user unmask "$1" >/dev/null 2>&1
  systemctl --user restart "$1" >/dev/null 2>&1
}

KILLED=""
ERRORS=""

# Rows accumulate here and are flushed to sql-ins.py once, after the loop.
LFILE=$(mktemp /tmp/omc_lblock.XXXXXX)

log_block() {
  pid="$1"
  name="$2"
  pattern="$3"
  printf 'event\t%s\tpublisher_block\t%s\tOmaControl\tBlocked forbidden app: %s (%s)\t0\n' \
    "$NOW" "$name" "$name" "$pattern" >>"$LFILE"
}

TMP=$(mktemp /tmp/omc_rules.XXXXXX)
KFILE=$(mktemp /tmp/omc_killed.XXXXXX)
EFILE=$(mktemp /tmp/omc_errors.XXXXXX)
PFILE=$(mktemp /tmp/omc_pfile.XXXXXX)
CUR_MASKED=$(mktemp /tmp/omc_masked.XXXXXX)
MSVC_LIST="$DATA_DIR/masked_services"
trap 'rm -f "$TMP" "$KFILE" "$EFILE" "$LFILE" "$PFILE" "$CUR_MASKED"' EXIT INT TERM

# One python pass parses the rules, applies the protected list and matches
# app rules against /proc (comm OR the full exe basename: comm is cut to 15
# characters). No per-process forks, so the bar can afford it every tick.
# Deliberately no command-line matching: argv can merely mention a name.
# Output lines: service|<unit>  protected|<pattern>  app|<pattern>|<pid>|<name>
python3 - "$RULES_FILE" "$SELF_DIR/protected-names" "$$" "${DRY_RUN:-0}" "${APPS_ONLY:-0}" >"$TMP" <<'PY'
import fnmatch, json, os, sys

rules_path, prot_path, parent = sys.argv[1], sys.argv[2], sys.argv[3]
dry, apps_only = sys.argv[4] == "1", sys.argv[5] == "1"
try:
    with open(rules_path) as f:
        data = json.load(f)
    rules = data.get("rules", []) if isinstance(data, dict) else []
except Exception:
    sys.exit()

# Fail closed: without a readable protected list, everything is protected.
try:
    with open(prot_path) as f:
        prot = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    def protected(name):
        return any(fnmatch.fnmatchcase(name, p) for p in prot)
except OSError:
    def protected(name):
        return True

def clean(s):
    return "".join(c for c in s if c not in '|"\\' and ord(c) >= 32 and ord(c) != 127)

apps = set()
for r in rules:
    if not isinstance(r, dict) or not r.get("enabled"):
        continue
    if r.get("action") not in ("disable", "kill"):
        continue
    pat = r.get("pattern", "")
    if not isinstance(pat, str) or not pat or clean(pat) != pat:
        continue
    if r.get("kind", "app") == "service":
        if apps_only:
            continue
        unit = pat[:-8] if pat.endswith(".service") else pat
        print(("protected|%s" if protected(unit) else "service|%s") % pat)
    elif protected(pat):
        print("protected|%s" % pat)
    else:
        apps.add(pat)

if apps and not dry:
    skip = {"1", parent, str(os.getpid()), str(os.getppid())}
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or pid in skip:
            continue
        try:
            with open("/proc/%s/comm" % pid) as f:
                comm = f.read().rstrip("\n")
        except OSError:
            continue
        try:
            exe = os.path.basename(os.readlink("/proc/%s/exe" % pid))
        except OSError:
            exe = ""
        hit = comm if comm in apps else (exe if exe in apps else "")
        # Re-check the actual process: an unprotected rule name must not
        # reach a protected process through its other name.
        if not hit or protected(comm) or (exe and protected(exe)):
            continue
        print("app|%s|%s|%s" % (hit, pid, clean(exe) or "unknown"))
PY

while IFS='|' read -r kind pattern pid name; do
  case "$kind" in
    service)
      # Track every unit this run asks to mask so we can un-mask the ones whose
      # rule went away — a mask once applied must not outlive the rule.
      if valid_unit "$pattern"; then
        # Status before masking, surfaced in the caller's JSON so the reviewer
        # can see exactly which unit was affected and in what state.
        # unit-state.sh keeps this to one bare line (systemctl exits nonzero for
        # inactive units, which would otherwise append "unknown" as a second
        # line and embed a raw newline in the JSON).
        STATE=$(sh "$SELF_DIR/unit-state.sh" "$pattern")
        if [ -z "$DRY_RUN" ]; then
          mask_unit "$pattern"
          echo "$pattern" >>"$CUR_MASKED"
        fi
        printf '%s\n' "{\"unit\":\"$pattern\",\"masked\":\"yes\",\"state\":\"$STATE\"}" >>"$KFILE"
      else
        printf '%s\n' "{\"unit\":\"$pattern\",\"error\":\"invalid unit name\"}" >>"$EFILE"
      fi
      ;;
    protected)
      printf '%s\n' "{\"pattern\":\"$pattern\",\"error\":\"protected session process\"}" >>"$EFILE"
      ;;
    app)
      printf '%s|%s|%s\n' "$pid" "$name" "$pattern" >>"$PFILE"
      ;;
  esac
done <"$TMP"

# Reap collected app-match targets with a SIGTERM grace before SIGKILL:
# a well-behaved app exits on TERM (a user kill, a rule, whatever), and only
# survivors after the grace get the SIGKILL. Every target is logged and
# reported, whether TERM or KILL ended it.
if [ -z "$DRY_RUN" ] && [ -s "$PFILE" ]; then
  while IFS='|' read -r pid name pat; do
    [ -z "$pid" ] && continue
    kill -TERM "$pid" 2>/dev/null
  done <"$PFILE"
  sleep 1
  while IFS='|' read -r pid name pat; do
    [ -z "$pid" ] && continue
    [ -d "/proc/$pid" ] && kill -KILL "$pid" 2>/dev/null
    log_block "$pid" "$name" "$pat"
    printf '%s\n' "{\"pid\":$pid,\"name\":\"$name\",\"pattern\":\"$pat\"}" >>"$KFILE"
  done <"$PFILE"
fi

# Unmask services whose disable rule vanished (or was disabled): the mask is
# persistent, so without this an enable/rule removal would never take effect.
# Every unit here is a legitimate-name from the tracked mask list (or a prior
# valid_unit()); unmask and return the unit to its prior lifecycle.
# --apps never looked at service rules, so it must not unmask anything.
if [ -z "$DRY_RUN" ] && [ -z "$APPS_ONLY" ] && [ -f "$MSVC_LIST" ]; then
  if [ -s "$CUR_MASKED" ]; then
    grep -Fxvf "$CUR_MASKED" "$MSVC_LIST" | while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      if valid_unit "$unit"; then
        unmask_unit "$unit"
        printf '%s\n' "{\"unit\":\"$unit\",\"masked\":\"no\"}" >>"$KFILE"
      fi
    done
  else
    grep -v '^$' "$MSVC_LIST" | while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      if valid_unit "$unit"; then
        unmask_unit "$unit"
        printf '%s\n' "{\"unit\":\"$unit\",\"masked\":\"no\"}" >>"$KFILE"
      fi
    done
  fi
  cp "$CUR_MASKED" "$MSVC_LIST" 2>/dev/null
  touch "$MSVC_LIST"
fi

# Flush audit rows through the parameterized writer (one transaction).
if [ -s "$LFILE" ]; then
  OMCONTROL_DB="$DB" python3 "$(dirname "$0")/sql-ins.py" <"$LFILE" 2>/dev/null
fi
KILLED_LIST="$(paste -sd, "$KFILE" 2>/dev/null)"
ERRORS_LIST="$(paste -sd, "$EFILE" 2>/dev/null)"
cat <<ENDJSON
{"killed":[$KILLED_LIST],"errors":[$ERRORS_LIST]}
ENDJSON
