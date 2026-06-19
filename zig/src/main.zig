//! Caveman/Ponytail UserPromptSubmit hook — Zig 0.16 PoC.
//!
//! Replaces the Node hook. Reads the hook JSON event on stdin, detects a
//! `/<tool> <level>` slash command (or natural-language activation), persists
//! the mode through a SYMLINK-SAFE flag write, and emits the hookSpecificOutput
//! JSON the harness injects back as per-turn reinforcement.
//!
//! Written against the stable libc C ABI (std.c + a couple of extern decls)
//! rather than the in-flight std.Io surface: a hook binary links libc anyway
//! and this keeps the PoC pinned to a stable interface. Production rewrite can
//! migrate to std.Io once 0.16 stabilizes; the security logic is identical.
//!
//! Shared primitives (TOOL, mode whitelist, getDefaultMode, the symlink-safe
//! flag write, flag path resolution, the libc IO helpers) now live in
//! common.zig — imported here and by activate.zig / statusline.zig so all three
//! binaries share one copy of the security core.

const std = @import("std");
const common = @import("common.zig");

const TOOL = common.TOOL; // "caveman" or "ponytail"

const canonicalMode = common.canonicalMode;
const isIndependentMode = common.isIndependentMode;
const getDefaultMode = common.getDefaultMode;
const flagPath = common.flagPath;
const safeWriteFlag = common.safeWriteFlag;
const unlinkFlag = common.unlinkFlag;
const readStdin = common.readStdin;
const writeStdout = common.writeStdout;

/// Extract the "prompt" string from the hook JSON via std.json (correct, not
/// hand-rolled). Returns an owned copy or null.
fn extractPrompt(gpa: std.mem.Allocator, input: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, input, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const p = obj.get("prompt") orelse return null;
    const s = switch (p) {
        .string => |str| str,
        else => return null,
    };
    return gpa.dupe(u8, s) catch null;
}

const ModeChange = union(enum) {
    activate: []const u8,
    deactivate,
};

fn slashArgMode(arg: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(arg, "wenyan-full")) return "wenyan";
    const mode = canonicalMode(arg) orelse return null;
    if (isIndependentMode(mode) or std.mem.eql(u8, mode, "off")) return null;
    return mode;
}

fn containsAny(prompt: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(prompt, needle) != null) return true;
    }
    return false;
}

fn orderedContains(prompt: []const u8, first: []const u8, second: []const u8) bool {
    const first_index = std.ascii.indexOfIgnoreCase(prompt, first) orelse return false;
    const tail = prompt[first_index + first.len ..];
    return std.ascii.indexOfIgnoreCase(tail, second) != null;
}

fn anyOrdered(prompt: []const u8, firsts: []const []const u8, second: []const u8) bool {
    for (firsts) |first| {
        if (orderedContains(prompt, first, second)) return true;
    }
    return false;
}

fn anyPairOrdered(prompt: []const u8, firsts: []const []const u8, seconds: []const []const u8) bool {
    for (seconds) |second| {
        if (anyOrdered(prompt, firsts, second)) return true;
    }
    return false;
}

fn parseDeactivation(prompt: []const u8) bool {
    const verbs = &.{ "stop", "disable", "deactivate", "turn off" };
    return containsAny(prompt, &.{"normal mode"}) or
        anyOrdered(prompt, verbs, "caveman") or
        anyPairOrdered(prompt, &.{"caveman"}, verbs);
}

fn parseNaturalActivation(prompt: []const u8, default_mode: []const u8) ?ModeChange {
    const before_caveman = &.{ "activate", "enable", "turn on", "start", "talk like" };
    const after_caveman = &.{ "mode", "activate", "enable", "turn on", "start" };
    if (anyOrdered(prompt, before_caveman, "caveman") or
        anyPairOrdered(prompt, &.{"caveman"}, after_caveman) or
        containsAny(prompt, &.{ "less tokens", "fewer tokens", "be brief", "be terse", "shorter answers" }))
    {
        if (std.mem.eql(u8, default_mode, "off")) return null;
        return .{ .activate = default_mode };
    }
    return null;
}

/// Parse slash commands → mode change, or null. Mirrors the JS mode-tracker.
fn parseSlashMode(prompt: []const u8, default_mode: []const u8) ?ModeChange {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const cmd = "/" ++ TOOL;
    const namespaced_cmd = "/" ++ TOOL ++ ":" ++ TOOL;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return null;

    if (std.ascii.eqlIgnoreCase(first, "/" ++ TOOL ++ "-commit")) return .{ .activate = "commit" };
    if (std.ascii.eqlIgnoreCase(first, "/" ++ TOOL ++ "-review")) return .{ .activate = "review" };
    if (std.ascii.eqlIgnoreCase(first, "/" ++ TOOL ++ "-compress") or
        std.ascii.eqlIgnoreCase(first, "/" ++ TOOL ++ ":" ++ TOOL ++ "-compress"))
    {
        return .{ .activate = "compress" };
    }

    // Exact first-token match — startsWith would accept "/<tool>x ..." and
    // wrongly activate mode parsing.
    if (!std.ascii.eqlIgnoreCase(first, cmd) and !std.ascii.eqlIgnoreCase(first, namespaced_cmd)) return null;

    const arg = it.next() orelse {
        if (std.mem.eql(u8, default_mode, "off")) return .deactivate;
        return .{ .activate = default_mode };
    };
    if (std.ascii.eqlIgnoreCase(arg, "off") or
        std.ascii.eqlIgnoreCase(arg, "stop") or
        std.ascii.eqlIgnoreCase(arg, "disable"))
    {
        return .deactivate;
    }
    if (slashArgMode(arg)) |mode| return .{ .activate = mode };
    return null;
}

fn parseModeChange(prompt: []const u8, default_mode: []const u8) ?ModeChange {
    if (parseDeactivation(prompt)) return .deactivate;
    if (parseSlashMode(prompt, default_mode)) |change| return change;
    return parseNaturalActivation(prompt, default_mode);
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input = readStdin(gpa) catch return; // silent-fail contract
    defer gpa.free(input);

    const prompt = extractPrompt(gpa, input) orelse return;
    defer gpa.free(prompt);

    const default_mode = getDefaultMode(gpa);
    const change = parseModeChange(prompt, default_mode) orelse return;

    // Silent-fail if env is missing/invalid (e.g. no HOME) — a hook must never
    // bubble an error out of main and disturb prompt submission.
    const path = flagPath(gpa) catch return;
    defer gpa.free(path);

    const mode = switch (change) {
        .deactivate => {
            unlinkFlag(path);
            return;
        },
        .activate => |mode| mode,
    };

    safeWriteFlag(gpa, path, mode) catch return; // silent-fail on FS errors
    if (isIndependentMode(mode)) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"");
    try out.appendSlice(gpa, TOOL);
    try out.appendSlice(gpa, " mode active: ");
    try out.appendSlice(gpa, mode);
    try out.appendSlice(gpa, "\"}}");
    writeStdout(out.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Shared-primitive tests (whitelist, getDefaultMode, safeWriteFlag) live in
// common.zig. These cover the mode-tracker-specific prompt parsing.

// Pull common's tests into this test binary too (so `zig build test` on
// main.zig exercises the shared security core as well).
test {
    std.testing.refAllDecls(common);
}

fn expectActivate(expected: []const u8, prompt: []const u8, default_mode: []const u8) !void {
    const change = parseModeChange(prompt, default_mode) orelse {
        try std.testing.expect(false);
        return;
    };
    switch (change) {
        .activate => |mode| try std.testing.expectEqualStrings(expected, mode),
        .deactivate => try std.testing.expect(false),
    }
}

fn expectDeactivate(prompt: []const u8, default_mode: []const u8) !void {
    const change = parseModeChange(prompt, default_mode) orelse {
        try std.testing.expect(false);
        return;
    };
    switch (change) {
        .activate => try std.testing.expect(false),
        .deactivate => {},
    }
}

test "parseModeChange slash commands mirror JS modes" {
    try expectActivate("full", "/" ++ TOOL, "full");
    try expectActivate("lite", "/" ++ TOOL, "lite");
    try expectActivate("ultra", "/" ++ TOOL ++ " ultra", "full");
    try expectActivate("wenyan", "/" ++ TOOL ++ " wenyan", "full");
    try expectActivate("wenyan", "/" ++ TOOL ++ " wenyan-full", "full");
    try expectActivate("commit", "/" ++ TOOL ++ "-commit", "full");
    try expectActivate("review", "/" ++ TOOL ++ "-review", "full");
    try expectActivate("compress", "/" ++ TOOL ++ "-compress", "full");
    try expectDeactivate("/" ++ TOOL ++ " off", "full");
    try expectDeactivate("/" ++ TOOL, "off");
    try std.testing.expect(parseModeChange("hello world", "full") == null);
    try std.testing.expect(parseModeChange("/" ++ TOOL ++ " bogus", "full") == null);
    try std.testing.expect(parseModeChange("/" ++ TOOL ++ "x ultra", "full") == null); // prefix, not exact
}

test "parseModeChange is case-insensitive" {
    try expectActivate("ultra", "/" ++ TOOL ++ " ULTRA", "full");
    const upper_cmd = if (std.mem.eql(u8, TOOL, "caveman")) "/CAVEMAN FuLl" else "/PONYTAIL FuLl";
    try expectActivate("full", upper_cmd, "lite");
}

test "parseModeChange natural language toggles" {
    try expectActivate("lite", "please talk like caveman now", "lite");
    try expectActivate("ultra", "LESS TOKENS please", "ultra");
    try expectDeactivate("normal mode", "full");
    try expectDeactivate("turn off caveman", "full");
    try expectDeactivate("stop talking like caveman", "full");
    try std.testing.expect(parseModeChange("activate caveman", "off") == null);
}

test "extractPrompt pulls prompt field" {
    const gpa = std.testing.allocator;
    const got = extractPrompt(gpa, "{\"prompt\":\"/" ++ TOOL ++ " ultra\",\"x\":1}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/" ++ TOOL ++ " ultra", got);
    try std.testing.expect(extractPrompt(gpa, "not json") == null);
}
