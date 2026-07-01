# Functional tests

Drive a whole binary (`zig-out/bin/<tool>-*`) via stdin/argv/env and assert
stdout/flag/file effects. Use the sandbox helper:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/sandbox.sh"
sandbox_new                       # throwaway HOME + CLAUDE_CONFIG_DIR
echo '{"prompt":"/caveman ultra"}' | "$(bin hook)" >/dev/null
assert_file_eq "name" "$CLAUDE_CONFIG_DIR/.caveman-active" "ultra"
sandbox_report
```

One `*.test.sh` per module. Run all: `tests/run-all.sh functional`.
See the master plan (`docs/superpowers/specs/2026-06-22-master-test-plan.json`)
for the per-module functional test list.
