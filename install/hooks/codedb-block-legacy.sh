#!/bin/bash
# codedb PreToolUse guard. Nudges agents from native file tools to codedb —
# but ONLY inside a codedb-indexed repo, and never for paths outside it.
# Fail-open by design (a nudge, not a wall). Disable entirely: CODEDB_NO_HOOKS=1.
[ -n "$CODEDB_NO_HOOKS" ] && exit 0
[ -f "$HOME/.codedb/no-hooks" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v codedb >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

STRIPPED=$(echo "$CMD" | sed -E 's/^[[:space:]]*(env|sudo|command|builtin|exec|nohup)[[:space:]]+//')
STRIPPED=$(echo "$STRIPPED" | sed -E 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
FIRST=$(echo "$STRIPPED" | awk '{print $1}')

case "$FIRST" in
  grep|rg|egrep|fgrep|cat|head|tail|find) ;;
  *) exit 0 ;;
esac

# Scope 1: cwd must sit at/under a codedb-indexed root. Otherwise codedb has
# nothing to offer here — allow the native tool (no blocking outside repos, on
# unindexed dirs, or in ~/.claude).
PWD_ABS=$(pwd -P)
REPO_ROOT=""
for pt in "$HOME"/.codedb/projects/*/project.txt; do
  [ -f "$pt" ] || continue
  root=$(head -1 "$pt" 2>/dev/null)
  [ -z "$root" ] && continue
  [ "$root" = "/" ] && continue        # degenerate root matches everything
  [ "$root" = "$HOME" ] && continue    # home indexed as a project would block all of ~
  if [ "$PWD_ABS" = "$root" ] || [ "${PWD_ABS#"$root"/}" != "$PWD_ABS" ]; then
    REPO_ROOT="$root"; break
  fi
done
[ -z "$REPO_ROOT" ] && exit 0

# Scope 2: if the command names an ABSOLUTE path outside this repo (cat /etc/hosts,
# grep x /tmp/f), codedb can't read it — allow. Relative paths are assumed
# in-repo (cwd is in-repo). Fail-open: any out-of-repo absolute arg -> allow.
set -f
for tok in $STRIPPED; do
  case "$tok" in
    /*)
      if [ "$tok" = "$REPO_ROOT" ] || [ "${tok#"$REPO_ROOT"/}" != "$tok" ]; then :; else set +f; exit 0; fi
      ;;
  esac
done
set +f

case "$FIRST" in
  grep|rg|egrep|fgrep) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_search \"<text>\" (codedb_word for an exact identifier, codedb_callers for call sites) instead of $FIRST — ranked + fewer tokens. Native $FIRST is allowed outside this repo or with CODEDB_NO_HOOKS=1." >&2; exit 2 ;;
  cat) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_read path=<file> (codedb_outline first for a map) instead of cat. CODEDB_NO_HOOKS=1 to disable." >&2; exit 2 ;;
  head|tail) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_read path=<file> line_start=.. line_end=.. instead of $FIRST. CODEDB_NO_HOOKS=1 to disable." >&2; exit 2 ;;
  find) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_find (fuzzy names) or codedb_glob (patterns) instead of find. CODEDB_NO_HOOKS=1 to disable." >&2; exit 2 ;;
esac
exit 0
