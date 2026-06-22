#!/usr/bin/env bash
# tests/run-all.sh — unified entrypoint for the whole caveman test suite.
#
# Runs every test class in order, fast-to-slow, and reports a single pass/fail.
# Used locally and by CI (.github/workflows/test-coverage.yml). Individual
# classes can be run alone with the first arg:
#     tests/run-all.sh              # everything
#     tests/run-all.sh zig          # just zig build test
#     tests/run-all.sh functional   # just tests/functional/*.test.sh
#     tests/run-all.sh js|python|differential|regression|e2e
#
# Env: TOOL=caveman|ponytail (default caveman), ZIG=<path>, COVERAGE=1 (zig kcov).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-/etc/profiles/per-user/etretiakov/bin/zig}"
TOOL="${TOOL:-caveman}"
WHICH="${1:-all}"
rc=0

run() { echo ""; echo "──── $1 ────"; shift; "$@"; local e=$?; [ $e -ne 0 ] && rc=1; return $e; }

zig_tests() {
  local cov=""
  [ "${COVERAGE:-0}" = "1" ] && cov="-Dtest-coverage"
  ( cd "$REPO/zig" && "$ZIG" build test -Dtool="$TOOL" $cov )
}
js_tests()     { ( cd "$REPO" && node --test tests/installer/*.test.mjs ) && node "$REPO/tests/test_symlink_flag.js" && node "$REPO/tests/test_repo_local_config.js"; }
python_tests() { ( cd "$REPO" && for f in tests/test_*.py; do echo "  $f"; python3 "$f" || return 1; done ); }
shell_class()  { # $1 = dir under tests/
  local dir="$REPO/tests/$1" any=0 e=0
  shopt -s nullglob
  for t in "$dir"/*.test.sh; do any=1; echo "  → $t"; TOOL="$TOOL" bash "$t" || e=1; done
  shopt -u nullglob
  [ "$any" = 0 ] && echo "  (no $1 tests yet)"
  return $e
}

case "$WHICH" in
  all)
    run "zig unit/in-source"  zig_tests
    run "functional"          shell_class functional
    run "regression"          shell_class regression
    run "differential"        shell_class differential
    run "e2e"                 shell_class e2e
    run "js (oracle)"         js_tests
    run "python (oracle)"     python_tests
    ;;
  zig)          run "zig" zig_tests;;
  functional)   run "functional" shell_class functional;;
  regression)   run "regression" shell_class regression;;
  differential) run "differential" shell_class differential;;
  e2e)          run "e2e" shell_class e2e;;
  js)           run "js" js_tests;;
  python)       run "python" python_tests;;
  *) echo "unknown class: $WHICH" >&2; exit 2;;
esac

echo ""
[ $rc -eq 0 ] && echo "✓ ALL GREEN ($WHICH, tool=$TOOL)" || echo "✗ FAILURES ($WHICH, tool=$TOOL)"
exit $rc
