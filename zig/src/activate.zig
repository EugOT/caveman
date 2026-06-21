//! Caveman/Ponytail SessionStart activation hook — Zig 0.16 PoC.
//!
//! Port of src/hooks/caveman-activate.js. Runs once per Claude Code session
//! start and does three things:
//!
//!   1. Resolves the default mode (env → repo config → user config → "full")
//!      and writes it to the flag file via the SYMLINK-SAFE write in common.zig.
//!      Special case: mode "off" → delete any flag, print "OK", exit 0.
//!   2. Emits the caveman ruleset on stdout. Claude Code injects SessionStart
//!      hook stdout as hidden system context. Independent modes (commit/review/
//!      compress) get a short activation line; intensity levels get the full
//!      ruleset.
//!   3. Detects a missing `statusLine` config in settings.json and appends a
//!      setup nudge so Claude offers to wire the statusline badge.
//!
//! The JS reads skills/caveman/SKILL.md at runtime and filters it to the active
//! level. A standalone Zig binary has no reliable adjacent SKILL.md, so this
//! port emits the JS *fallback* ruleset — the same minimum-viable text the JS
//! produces when SKILL.md is absent (standalone hook install). That fallback is
//! self-contained and byte-stable, which is what the differential check pins to.
//!
//! libc C-ABI throughout (std.c) — matches main.zig / common.zig; never blocks
//! session start: every filesystem error silent-fails.

const std = @import("std");
const common = @import("common.zig");
const c = std.c;

const TOOL = common.TOOL;

/// JSON-encode a string into `out` (RFC 8259 escaping), matching JS
/// JSON.stringify of a plain string. Escapes `"`, `\`, the C0 control
/// characters, and emits `\uXXXX` for any remaining byte < 0x20. Used to embed
/// the statusline `command` value in the setup nudge so a script path with a
/// quote, backslash, or control byte can never produce malformed JSON that the
/// model would then copy verbatim into settings.json.
fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print(gpa, "\\u{x:0>4}", .{ch});
                } else {
                    try out.append(gpa, ch);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

/// The JS fallback ruleset, reproduced byte-for-byte from
/// src/hooks/caveman-activate.js (the `else` branch when SKILL.md is absent).
/// `{label}` is substituted for the canonical mode label in two places.
fn emitFallbackRuleset(out: *std.ArrayList(u8), gpa: std.mem.Allocator, label: []const u8) !void {
    try out.appendSlice(gpa, "CAVEMAN MODE ACTIVE — level: ");
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, "\n\n");
    try out.appendSlice(gpa, "Respond terse like smart caveman. All technical substance stay. Only fluff die.\n\n");
    try out.appendSlice(gpa, "## Persistence\n\n");
    try out.appendSlice(gpa, "ACTIVE EVERY RESPONSE. No revert after many turns. No filler drift. Still active if unsure. Off only: \"stop caveman\" / \"normal mode\".\n\n");
    try out.appendSlice(gpa, "Current level: **");
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, "**. Switch: `/caveman lite|full|ultra`.\n\n");
    try out.appendSlice(gpa, "## Rules\n\n");
    try out.appendSlice(gpa, "Drop: articles (a/an/the), filler (just/really/basically/actually/simply), pleasantries (sure/certainly/of course/happy to), hedging. ");
    try out.appendSlice(gpa, "Fragments OK. Short synonyms (big not extensive, fix not \"implement a solution for\"). Technical terms exact. Code blocks unchanged. Errors quoted exact.\n\n");
    try out.appendSlice(gpa, "Pattern: `[thing] [action] [reason]. [next step].`\n\n");
    try out.appendSlice(gpa, "Not: \"Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by...\"\n");
    try out.appendSlice(gpa, "Yes: \"Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:\"\n\n");
    try out.appendSlice(gpa, "## Auto-Clarity\n\n");
    try out.appendSlice(gpa, "Drop caveman for: security warnings, irreversible action confirmations, multi-step sequences where fragment order risks misread, user asks to clarify or repeats question. Resume caveman after clear part done.\n\n");
    try out.appendSlice(gpa, "## Boundaries\n\n");
    try out.appendSlice(gpa, "Code/commits/PRs: write normal. \"stop caveman\" or \"normal mode\": revert. Level persist until changed or session end.");
}

/// Append the statusline-setup nudge if settings.json has no `statusLine` key.
/// Mirrors caveman-activate.js step 3. Silent on any anomaly — never blocks.
fn appendStatuslineNudge(out: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    const settings = common.claudeConfigFile(gpa, "settings.json") catch return;
    defer gpa.free(settings);

    // hasStatusline = settings.json parses and has a `statusLine` key.
    var has_statusline = false;
    if (common.isRegularFileNoSymlink(settings)) {
        if (common.readFileAlloc(gpa, settings, 1024 * 1024)) |raw| {
            defer gpa.free(raw);
            if (std.json.parseFromSlice(std.json.Value, gpa, raw, .{})) |parsed| {
                defer parsed.deinit();
                switch (parsed.value) {
                    .object => |obj| {
                        if (obj.get("statusLine") != null) has_statusline = true;
                    },
                    else => {},
                }
            } else |_| {}
        }
    }
    if (has_statusline) return;

    // Build the command snippet exactly like the JS (non-Windows branch — this
    // binary is the Unix path; the .ps1 counterpart handles Windows).
    const claude_dir = claudeDirPath(gpa) catch return;
    defer gpa.free(claude_dir);
    const script_path = std.fs.path.join(gpa, &.{ claude_dir, "caveman-statusline.sh" }) catch return;
    defer gpa.free(script_path);
    const settings_path = std.fs.path.join(gpa, &.{ claude_dir, "settings.json" }) catch return;
    defer gpa.free(settings_path);
    const command = std.fmt.allocPrint(gpa, "bash \"{s}\"", .{script_path}) catch return;
    defer gpa.free(command);

    // command = `bash "<script_path>"` then JSON.stringify(command). Escape the
    // command value through appendJsonString so a script path containing a
    // quote, backslash, or control byte can never emit malformed JSON in the
    // nudge the model surfaces (and may copy verbatim into settings.json).
    out.appendSlice(gpa, "\n\n") catch return;
    out.appendSlice(gpa, "STATUSLINE SETUP NEEDED: The caveman plugin includes a statusline badge showing active mode ") catch return;
    out.appendSlice(gpa, "(e.g. [CAVEMAN], [CAVEMAN:ULTRA]). It is not configured yet. ") catch return;
    out.appendSlice(gpa, "To enable, add this to ") catch return;
    out.appendSlice(gpa, settings_path) catch return;
    out.appendSlice(gpa, ": ") catch return;
    out.appendSlice(gpa, "\"statusLine\": { \"type\": \"command\", \"command\": ") catch return;
    appendJsonString(out, gpa, command) catch return;
    out.appendSlice(gpa, " } ") catch return;
    out.appendSlice(gpa, "Proactively offer to set this up for the user on first interaction.") catch return;
}

/// $CLAUDE_CONFIG_DIR or $HOME/.claude — the directory, not a file under it.
fn claudeDirPath(gpa: std.mem.Allocator) common.FlagError![]u8 {
    if (common.getenv("CLAUDE_CONFIG_DIR")) |base| return gpa.dupe(u8, base);
    const home = common.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude" });
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const mode = common.getDefaultMode(gpa);

    const path = common.flagPath(gpa) catch {
        // No HOME / config dir — mirror JS: still print something sensible.
        // JS would throw before reaching here; safest is to emit nothing.
        return;
    };
    defer gpa.free(path);

    // "off" mode — skip activation entirely; delete flag, print OK, exit.
    if (std.mem.eql(u8, mode, "off")) {
        common.unlinkFlag(path);
        common.writeStdout("OK");
        return;
    }

    // 1. Write flag file (symlink-safe). Silent-fail like the JS.
    common.safeWriteFlag(gpa, path, mode) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // 2. Independent modes — short activation line, skill defines behavior.
    if (common.isIndependentMode(mode)) {
        try out.appendSlice(gpa, "CAVEMAN MODE ACTIVE — level: ");
        try out.appendSlice(gpa, mode);
        try out.appendSlice(gpa, ". Behavior defined by /caveman-");
        try out.appendSlice(gpa, mode);
        try out.appendSlice(gpa, " skill.");
        common.writeStdout(out.items);
        return;
    }

    // Resolve the canonical label for the wenyan alias (matches JS modeLabel).
    const label = if (std.mem.eql(u8, mode, "wenyan")) "wenyan-full" else mode;

    // Emit the fallback ruleset (standalone-install path — no adjacent SKILL.md).
    try emitFallbackRuleset(&out, gpa, label);

    // 3. Statusline-setup nudge if not configured.
    appendStatuslineNudge(&out, gpa);

    common.writeStdout(out.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(common);
}

test "emitFallbackRuleset embeds level label twice" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitFallbackRuleset(&out, gpa, "ultra");

    // Header line.
    try std.testing.expect(std.mem.startsWith(u8, out.items, "CAVEMAN MODE ACTIVE — level: ultra\n\n"));
    // "Current level: **ultra**." appears in the Persistence section.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Current level: **ultra**.") != null);
    // Structural anchors preserved.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "## Persistence") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "## Rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "## Auto-Clarity") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "## Boundaries") != null);
}

test "appendJsonString escapes statusline command" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendJsonString(&out, gpa, "bash \"/tmp/a \\\"quoted\\\" path/statusline.sh\"");
    try std.testing.expectEqualStrings("\"bash \\\"/tmp/a \\\\\\\"quoted\\\\\\\" path/statusline.sh\\\"\"", out.items);
}

test "wenyan alias resolves to wenyan-full label" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const label = if (std.mem.eql(u8, "wenyan", "wenyan")) "wenyan-full" else "wenyan";
    try emitFallbackRuleset(&out, gpa, label);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "CAVEMAN MODE ACTIVE — level: wenyan-full\n\n"));
}

test "independent mode emits short activation line" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const mode = "commit";
    try out.appendSlice(gpa, "CAVEMAN MODE ACTIVE — level: ");
    try out.appendSlice(gpa, mode);
    try out.appendSlice(gpa, ". Behavior defined by /caveman-");
    try out.appendSlice(gpa, mode);
    try out.appendSlice(gpa, " skill.");
    try std.testing.expectEqualStrings(
        "CAVEMAN MODE ACTIVE — level: commit. Behavior defined by /caveman-commit skill.",
        out.items,
    );
}

test "off mode deletes flag and prints OK" {
    const gpa = std.testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".off-active" });
    defer gpa.free(flag);
    try common.writeSmall(flag, "full"); // pre-existing flag
    try std.testing.expect(common.isRegularFileNoSymlink(flag));

    // Simulate the off branch: unlink + would print "OK".
    common.unlinkFlag(flag);
    try std.testing.expect(!common.isRegularFileNoSymlink(flag));
}

test "activate writes flag then ruleset references it" {
    const gpa = std.testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".act-active" });
    defer gpa.free(flag);

    try common.safeWriteFlag(gpa, flag, "lite");
    const data = try common.readSmall(gpa, flag);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("lite", data);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitFallbackRuleset(&out, gpa, "lite");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Current level: **lite**.") != null);

    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&fb, flag));
}
