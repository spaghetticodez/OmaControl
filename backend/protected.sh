#!/bin/sh
# OmaControl protected-process check, sourced by app-action.sh.
#
# is_protected NAME -> exit 0 when NAME matches a pattern in protected-names.
# Fails closed: an unreadable list protects everything. Callers set SELF_DIR
# to the backend directory (as every backend script already does).
PROTECTED_NAMES="${SELF_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}/protected-names"

is_protected() {
  [ -r "$PROTECTED_NAMES" ] || return 0
  while IFS= read -r _pat; do
    case "$_pat" in '' | '#'*) continue ;; esac
    # Unquoted on purpose: each line is a glob pattern.
    # shellcheck disable=SC2254
    case "$1" in $_pat) return 0 ;; esac
  done <"$PROTECTED_NAMES"
  return 1
}
