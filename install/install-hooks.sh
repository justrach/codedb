#!/usr/bin/env bash
# codedb hook installer — packaged as share/codedb/install-hooks.sh and run by
# `codedb install-hooks` (and by install.sh at the end of an install).
#
# Hooks execute arbitrary commands with your user permissions. They are a nudge
# toward codedb's tools, not a security boundary. Opt out with CODEDB_NO_HOOKS=1
# (this run only) or CODEDB_PERSIST_NO_HOOKS=1 / `touch ~/.codedb/no-hooks`.
set -euo pipefail

codedb_bin="${CODEDB_BIN:-codedb}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codedb-bin)
      if [ -z "${2:-}" ]; then
        printf 'usage: install-hooks.sh [--codedb-bin /path/to/codedb]\n' >&2
        exit 1
      fi
      codedb_bin="$2"
      shift 2
      ;;
    -h|--help)
      printf 'usage: install-hooks.sh [--codedb-bin /path/to/codedb]\n'
      exit 0
      ;;
    *)
      printf 'install-hooks.sh: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  printf 'codedb: install-hooks requires python3\n' >&2
  exit 1
fi

python3 - "$codedb_bin" << 'PYEOF'
import json
import os
import re
import shlex
import stat
import sys

codedb_bin = sys.argv[1]
codedb_bin_q = shlex.quote(codedb_bin)
home = os.path.expanduser("~")

# Every generated hook script starts with this: prefer the exact binary the
# installer resolved (nix profiles and ~/bin are often absent from the minimal
# PATH a hook subshell inherits), fall back to PATH lookup, and fail open when
# codedb is not installed at all.
RESOLVE_BIN = '''CODEDB_BIN=@CODEDB_BIN@
if [ -x "$CODEDB_BIN" ]; then
  :
elif command -v "$CODEDB_BIN" >/dev/null 2>&1; then
  CODEDB_BIN="$(command -v "$CODEDB_BIN")"
else
  exit 0
fi'''


def render(script):
    return script.replace("@RESOLVE_BIN@", RESOLVE_BIN).replace("@CODEDB_BIN@", codedb_bin_q)


def write_executable(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


# Merge codedb hooks without clobbering existing hooks from other tools.
# If a competing legacy-tools hook is already registered for the same
# event/matcher (e.g. muonry's block-legacy-tools.sh), insert codedb's
# entry at the FRONT of the list so its redirect wins the race; otherwise
# append. Re-runs will also reshuffle an already-registered codedb hook
# to the front if a competitor has appeared since the previous install.
COMPETITOR_MARKERS = ("block-legacy-tools", "muonry", "zigrep", "zigread")


def merge_hook(settings, event, new_entry, competitor_markers=()):
    hooks = settings.setdefault("hooks", {})
    existing = hooks.get(event, [])
    cmd = new_entry["hooks"][0]["command"]
    matcher = new_entry.get("matcher", "")
    competes = any(
        e.get("matcher", "") == matcher
        and any(any(m in h.get("command", "") for m in competitor_markers) for h in e.get("hooks", []))
        for e in existing
    )
    idx = None
    for i, e in enumerate(existing):
        if any(cmd in h.get("command", "") for h in e.get("hooks", [])):
            idx = i
            break
    if idx is not None:
        if competes and idx != 0:
            existing.insert(0, existing.pop(idx))
            hooks[event] = existing
        return
    if competes:
        existing.insert(0, new_entry)
    else:
        existing.append(new_entry)
    hooks[event] = existing


BLOCK_LEGACY = r'''#!/usr/bin/env bash
# codedb PreToolUse guard. Nudges agents from native file tools to codedb —
# but ONLY inside a codedb-indexed repo, and never for paths outside it.
# Fail-open by design (a nudge, not a wall). Disable entirely: CODEDB_NO_HOOKS=1.
[ -n "$CODEDB_NO_HOOKS" ] && exit 0
[ -f "$HOME/.codedb/no-hooks" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
@RESOLVE_BIN@

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

STRIPPED=$(echo "$CMD" | sed -E 's/^[[:space:]]*(env|sudo|command|builtin|exec|nohup)[[:space:]]+//')
STRIPPED=$(echo "$STRIPPED" | sed -E 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
FIRST=$(echo "$STRIPPED" | awk '{print $1}')

case "$FIRST" in
  grep|rg|egrep|fgrep|cat|head|tail|sed|awk|find) ;;
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
  sed|awk) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_search/codedb_read to locate the lines, then your editor tool to change them, instead of $FIRST. CODEDB_NO_HOOKS=1 to disable." >&2; exit 2 ;;
  find) echo "BLOCKED in indexed repo ($REPO_ROOT): use codedb_find (fuzzy names) or codedb_glob (patterns) instead of find. CODEDB_NO_HOOKS=1 to disable." >&2; exit 2 ;;
esac
exit 0
'''

WARMUP = r'''#!/usr/bin/env bash
@RESOLVE_BIN@
"$CODEDB_BIN" . status >/dev/null 2>&1 &
exit 0
'''

SEARCH_GUARD = r'''#!/usr/bin/env bash
# codedb Codex PreToolUse guard: deny only a deliberate over-fetch. A missing
# max_results is fine (the server defaults to 20) — this exists to stop a single
# call from dumping hundreds of ranked hits into the context window.
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
max_results="$(printf '%s' "$input" | jq -r '.tool_input.max_results // empty')"

case "$max_results" in
  ''|*[!0-9]*) exit 0 ;;
esac

if [ "$max_results" -gt 100 ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use codedb_search with max_results of 100 or less, then page with offset."
    }
  }'
fi
'''


def install_claude_hooks():
    hooks_dir = os.path.join(home, ".claude", "hooks")
    settings_path = os.path.join(home, ".claude", "settings.json")
    os.makedirs(hooks_dir, exist_ok=True)

    # Opt-out: CODEDB_NO_HOOKS=1 skips (re-)registering the PreToolUse
    # block-legacy hook for THIS run only. It is deliberately NOT persisted: the
    # background auto-updater re-runs this installer with the environment it
    # inherited from the codedb process (src/update.zig), so a transient export
    # must never become a permanent on-disk opt-out. Persist it explicitly with
    # CODEDB_PERSIST_NO_HOOKS=1 or `touch ~/.codedb/no-hooks`; `rm` that file to
    # re-enable. A deliberate removal from settings.json also persists (#658).
    no_hooks_marker = os.path.join(home, ".codedb", "no-hooks")

    def persist_no_hooks():
        os.makedirs(os.path.dirname(no_hooks_marker), exist_ok=True)
        with open(no_hooks_marker, "w") as f:
            f.write("")

    skip_pretooluse = bool(os.environ.get("CODEDB_NO_HOOKS")) or os.path.exists(no_hooks_marker)
    if os.environ.get("CODEDB_PERSIST_NO_HOOKS") and not os.path.exists(no_hooks_marker):
        persist_no_hooks()
        skip_pretooluse = True

    settings = load_json(settings_path)
    hooks = settings.setdefault("hooks", {})

    # #658: honor a deliberate removal. If a previous run registered the
    # PreToolUse hook (receipt exists) but its settings.json entry is gone, the
    # user deleted it — persist the opt-out marker instead of re-adding the hook
    # on the next unattended auto-update run. This runs BEFORE the scripts are
    # written so the removed hook script does not reappear on disk either.
    hooks_receipt = os.path.join(home, ".codedb", "hooks-registered")

    def pretooluse_entry_present():
        for e in hooks.get("PreToolUse", []):
            for h in e.get("hooks", []):
                if "codedb-block-legacy.sh" in h.get("command", ""):
                    return True
        return False

    if not skip_pretooluse and os.path.exists(hooks_receipt) and not pretooluse_entry_present():
        persist_no_hooks()
        skip_pretooluse = True

    if not skip_pretooluse:
        write_executable(os.path.join(hooks_dir, "codedb-block-legacy.sh"), render(BLOCK_LEGACY))
    write_executable(os.path.join(hooks_dir, "codedb-warmup.sh"), render(WARMUP))

    if not skip_pretooluse:
        merge_hook(settings, "PreToolUse", {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/codedb-block-legacy.sh"}],
        }, COMPETITOR_MARKERS)
        os.makedirs(os.path.dirname(hooks_receipt), exist_ok=True)
        with open(hooks_receipt, "w") as f:
            f.write("")
    merge_hook(settings, "SessionStart", {
        "matcher": "",
        "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/codedb-warmup.sh"}],
    })

    # Auto-allow codedb's own MCP tools so callers aren't prompted for every
    # codedb_* call. Purely additive — we add only the codedb-scoped rule and
    # never touch other servers' permissions. The "mcp__codedb__*" form (literal
    # server prefix + tool glob) is the syntax Claude Code's permission validator
    # accepts; a bare "mcp__*" is rejected and silently skipped.
    perms = settings.setdefault("permissions", {})
    allow = perms.setdefault("allow", [])
    if isinstance(allow, list) and "mcp__codedb__*" not in allow:
        allow.append("mcp__codedb__*")

    write_json(settings_path, settings)
    return skip_pretooluse


def ensure_codex_hooks_feature(config_path):
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    try:
        with open(config_path) as f:
            text = f.read()
    except FileNotFoundError:
        text = ""

    if re.search(r"(?m)^\s*codex_hooks\s*=", text):
        text = re.sub(r"(?m)^\s*codex_hooks\s*=\s*[^\n#]*(.*)$", r"codex_hooks = true\1", text, count=1)
    elif re.search(r"(?m)^\s*\[features\]\s*$", text):
        text = re.sub(r"(?m)^(\s*\[features\]\s*)$", r"\1\ncodex_hooks = true", text, count=1)
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        if text:
            text += "\n"
        text += "[features]\ncodex_hooks = true\n"

    with open(config_path, "w") as f:
        f.write(text)


def install_codex_hooks():
    hooks_dir = os.path.join(home, ".codex", "hooks")
    hooks_path = os.path.join(home, ".codex", "hooks.json")
    config_path = os.path.join(home, ".codex", "config.toml")

    write_executable(os.path.join(hooks_dir, "codedb-search-guard.sh"), render(SEARCH_GUARD))
    ensure_codex_hooks_feature(config_path)

    settings = load_json(hooks_path)
    merge_hook(settings, "PreToolUse", {
        "matcher": "mcp__codedb__codedb_search",
        "hooks": [{
            "type": "command",
            "command": "/usr/bin/env bash \"$HOME/.codex/hooks/codedb-search-guard.sh\"",
            "timeout": 5,
            "statusMessage": "Checking codedb_search request",
        }],
    })
    write_json(hooks_path, settings)


skipped_pretooluse = install_claude_hooks()
install_codex_hooks()

print("codedb hooks installed:")
if skipped_pretooluse:
    print("  claude -> ~/.claude/hooks/codedb-warmup.sh (PreToolUse guard opted out)")
else:
    print("  claude -> ~/.claude/hooks/ + ~/.claude/settings.json")
print("  codex  -> ~/.codex/hooks/ + ~/.codex/hooks.json + codex_hooks=true")
PYEOF
