#!/usr/bin/env bash
# tests/lib/sandbox.sh — shared sandbox + assertion helpers for caveman shell tests
# (functional / regression / e2e / differential).
#
# Source this at the top of a test script:
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/sandbox.sh"
#     sandbox_new                 # sets SANDBOX, HOME, CLAUDE_CONFIG_DIR (throwaway)
#     ... drive a binary, assert ...
#     # cleanup is automatic on EXIT
#
# Every sandbox is a fresh mktemp dir, removed by a trap. HOME and
# CLAUDE_CONFIG_DIR point inside it so no test ever touches the real ~/.claude.
set -uo pipefail

# ── repo paths ────────────────────────────────────────────────────────────────
TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_LIB_DIR/../.." && pwd)"
ZIG_BIN_DIR="$REPO_ROOT/zig/zig-out/bin"
ZIG="${ZIG:-/etc/profiles/per-user/etretiakov/bin/zig}"
TOOL="${TOOL:-caveman}"

# ── counters ──────────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_SANDBOXES=()

# ── sandbox lifecycle ─────────────────────────────────────────────────────────
sandbox_new() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/caveman-sbx.XXXXXX")"
  _SANDBOXES+=("$SANDBOX")
  export HOME="$SANDBOX/home"
  export CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  # Drop any caveman env that would leak the host default mode into the test.
  unset CAVEMAN_DEFAULT_MODE PONYTAIL_DEFAULT_MODE 2>/dev/null || true
}

_sandbox_cleanup() { for d in "${_SANDBOXES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap _sandbox_cleanup EXIT INT TERM

# ── binary resolution ─────────────────────────────────────────────────────────
# bin <suffix>  → absolute path to zig-out/bin/<tool>-<suffix>; builds on demand.
bin() {
  local p="$ZIG_BIN_DIR/$TOOL-$1"
  if [ ! -x "$p" ]; then
    ( cd "$REPO_ROOT/zig" && "$ZIG" build -Dtool="$TOOL" ) >/dev/null 2>&1 || true
  fi
  printf '%s' "$p"
}

# ── assertions ────────────────────────────────────────────────────────────────
_ok()   { _PASS=$((_PASS+1)); printf '  ok   %s\n' "$1"; }
_nok()  { _FAIL=$((_FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then _ok "$1"; else _nok "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) _ok "$1";; *) _nok "$1" "[$2] does not contain [$3]";; esac
}
assert_file_eq() { # name path expected-content
  local got; got="$(cat "$2" 2>/dev/null || echo '<missing>')"
  if [ "$got" = "$3" ]; then _ok "$1"; else _nok "$1" "file [$2]: expected [$3] got [$got]"; fi
}
assert_file_absent() { # name path
  if [ ! -e "$2" ]; then _ok "$1"; else _nok "$1" "file [$2] exists but should not"; fi
}
assert_file_present() { # name path
  if [ -e "$2" ]; then _ok "$1"; else _nok "$1" "file [$2] missing"; fi
}

# ── differential helper ───────────────────────────────────────────────────────
# diff_eq name "zig output" "oracle output" — byte-compare Zig vs JS/Py oracle.
diff_eq() { assert_eq "$1" "$3" "$2"; }

# ── summary / exit ────────────────────────────────────────────────────────────
sandbox_report() {
  printf '\n  %d passed, %d failed\n' "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
