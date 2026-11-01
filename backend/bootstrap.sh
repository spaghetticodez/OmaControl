#!/bin/sh
# OmaControl secure-execution bootstrap.
#
# Sourced immediately after a script's shebang (or by the python entrypoints'
# spawning process). It normalizes the environment so that no collector can be
# influenced by anything inherited from the caller:
#
#   * PATH is replaced with a fixed, root-owned allowlist. A shadow executable
#     dropped anywhere else on the user's PATH (~/bin, a repo dir, ...) can
#     never be resolved here.
#   * Locale is pinned to C so ps/sqlite/jq output parsing is deterministic.
#   * Dynamic-loader and interpreter module injection variables are dropped.
#   * The plugin data directory is guaranteed to exist.
umask 077

export PATH=/usr/bin:/bin
export LC_ALL=C

unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_LIBRARY_PATH_64 \
  PYTHONHOME PYTHONSTARTUP PYTHONPATH PERL5LIB PERLLIB 2>/dev/null || true

: "${OMCONTROL_DATA_DIR:=$HOME/.local/share/omcontrol}"
export OMCONTROL_DATA_DIR
# Every helper sources this on every tick: only fork mkdir when needed.
[ -d "$OMCONTROL_DATA_DIR" ] || mkdir -p "$OMCONTROL_DATA_DIR" 2>/dev/null || true

# Tick-to-tick state (rewritten every tick, meaningless after a reboot) lives
# on tmpfs: $XDG_RUNTIME_DIR/omcontrol, else /run/user/<uid>/omcontrol, else
# the data dir. OMCONTROL_RUN_DIR overrides (tests). Call when needed; it
# only forks when the directory has to be created.
omc_run_dir() {
  if [ -z "${OMCONTROL_RUN_DIR:-}" ]; then
    OMCONTROL_RUN_DIR="$OMCONTROL_DATA_DIR"
    _rt="${XDG_RUNTIME_DIR:-}"
    [ -n "$_rt" ] || _rt="/run/user/$(id -u)"
    [ -d "$_rt" ] && [ -w "$_rt" ] && OMCONTROL_RUN_DIR="$_rt/omcontrol"
  fi
  if [ ! -d "$OMCONTROL_RUN_DIR" ]; then
    mkdir -p "$OMCONTROL_RUN_DIR" 2>/dev/null && chmod 700 "$OMCONTROL_RUN_DIR" 2>/dev/null
  fi
  [ -d "$OMCONTROL_RUN_DIR" ] && [ -w "$OMCONTROL_RUN_DIR" ] || OMCONTROL_RUN_DIR="$OMCONTROL_DATA_DIR"
  export OMCONTROL_RUN_DIR
}

# Hard ceiling for any helper's stdout, applied by run-capped.sh and by the
# producers themselves. Payloads are element-bounded (fixed count/window
# limits), well under this in practice; the cap bounds worst-case retention
# in the long-lived shell if a producer ever runs away.
: "${OMCONTROL_MAX_OUT_BYTES:=1048576}"
export OMCONTROL_MAX_OUT_BYTES
