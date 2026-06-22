#!/usr/bin/env bash
# Smoke functional test proving the sandbox scaffolding works end-to-end against
# the real caveman-hook binary. (The full main.zig functional suite is task #65.)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/sandbox.sh"

HOOK="$(bin hook)"

# 1. fresh write: /caveman ultra → flag = ultra
sandbox_new
echo '{"prompt":"/caveman ultra"}' | "$HOOK" >/dev/null 2>&1
assert_file_eq "fresh write '/caveman ultra' → flag=ultra" "$CLAUDE_CONFIG_DIR/.caveman-active" "ultra"

# 2. deactivate: seed flag, 'stop caveman' → flag removed
sandbox_new
printf 'ultra' > "$CLAUDE_CONFIG_DIR/.caveman-active"
echo '{"prompt":"stop caveman"}' | "$HOOK" >/dev/null 2>&1
assert_file_absent "natural-language 'stop caveman' removes flag" "$CLAUDE_CONFIG_DIR/.caveman-active"

# 3. per-turn reinforcement: seeded flag, plain prompt → reminder on stdout
sandbox_new
printf 'ultra' > "$CLAUDE_CONFIG_DIR/.caveman-active"
OUT="$(echo '{"prompt":"plain question"}' | "$HOOK" 2>/dev/null)"
assert_contains "plain prompt emits per-turn reinforcement" "$OUT" "CAVEMAN MODE ACTIVE (ultra)"

sandbox_report
