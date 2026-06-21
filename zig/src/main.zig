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
// Uppercased tool name for the per-turn reinforcement text ("CAVEMAN MODE
// ACTIVE (...)"), computed at comptime since TOOL is comptime-known.
const TOOL_UPPER = blk: {
    var buf: [TOOL.len]u8 = undefined;
    for (TOOL, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    const final = buf;
    break :blk &final;
};

const c = std.c;
const canonicalMode = common.canonicalMode;
const isIndependentMode = common.isIndependentMode;
const getDefaultMode = common.getDefaultMode;
const flagPath = common.flagPath;
const safeWriteFlag = common.safeWriteFlag;
const unlinkFlag = common.unlinkFlag;
const readStdin = common.readStdin;
const writeStdout = common.writeStdout;

extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Extract a top-level string field from the hook JSON. Returns an owned copy
/// or null. Used for both "prompt" and "transcript_path".
fn extractStringField(gpa: std.mem.Allocator, input: []const u8, field: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, input, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(field) orelse return null;
    const s = switch (v) {
        .string => |str| str,
        else => return null,
    };
    return gpa.dupe(u8, s) catch null;
}

fn extractPrompt(gpa: std.mem.Allocator, input: []const u8) ?[]u8 {
    return extractStringField(gpa, input, "prompt");
}

/// fork + pipe + capture a child's stdout into an owned buffer. Mirrors the
/// captureSpawn pattern in install.zig. argv must be NUL-terminated slices;
/// execvp searches $PATH (the installer puts the binaries on PATH). Returns the
/// captured stdout (owned) or null on spawn failure. stderr is discarded.
fn captureStdout(gpa: std.mem.Allocator, argv: []const [:0]const u8) ?[]u8 {
    if (argv.len == 0) return null;
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return null;

    const cargv = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        _ = common.close(fds[0]);
        _ = common.close(fds[1]);
        return null;
    };
    defer gpa.free(cargv);
    for (argv, 0..) |a, i| cargv[i] = a.ptr;

    const pid = fork();
    if (pid < 0) {
        _ = common.close(fds[0]);
        _ = common.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        const devnull = c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
        if (devnull >= 0) _ = c.dup2(devnull, 2);
        _ = common.close(fds[0]);
        _ = common.close(fds[1]);
        _ = execvp(argv[0].ptr, cargv.ptr);
        c._exit(127);
    }
    _ = common.close(fds[1]);
    var buf: std.ArrayList(u8) = .empty;
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fds[0], &rbuf, rbuf.len);
        if (n <= 0) break;
        buf.appendSlice(gpa, rbuf[0..@intCast(n)]) catch break;
    }
    _ = common.close(fds[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return buf.toOwnedSlice(gpa) catch null;
}

/// Append `s` to `out` as a JSON-escaped string body (between quotes).
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (ch < 0x20) {
            try out.appendSlice(gpa, "\\u00");
            const hex = "0123456789abcdef";
            try out.append(gpa, hex[(ch >> 4) & 0xf]);
            try out.append(gpa, hex[ch & 0xf]);
        } else try out.append(gpa, ch),
    };
}

/// /caveman-stats handler: detect the slash command, run the caveman-stats
/// binary (PATH-resolved) with --session-file <transcript_path> and passthrough
/// flags, and emit {"decision":"block","reason":<stats output>}. Mirrors
/// caveman-mode-tracker.js lines 41-62. Returns true if handled (caller exits).
fn handleStats(gpa: std.mem.Allocator, prompt: []const u8, input: []const u8) bool {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const a = "/" ++ TOOL ++ "-stats";
    const b = "/" ++ TOOL ++ ":" ++ TOOL ++ "-stats";
    // First token must be exactly the stats command (allow trailing args).
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, a) and !std.ascii.eqlIgnoreCase(first, b)) return false;

    // Build argv: caveman-stats [--session-file <path>] [--share] [--all] [--since <v>].
    var args: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }
    args.append(gpa, gpa.dupeZ(u8, TOOL ++ "-stats") catch return blockReason(gpa, statsErr())) catch return blockReason(gpa, statsErr());

    if (extractStringField(gpa, input, "transcript_path")) |tp| {
        defer gpa.free(tp);
        args.append(gpa, gpa.dupeZ(u8, "--session-file") catch return blockReason(gpa, statsErr())) catch {};
        args.append(gpa, gpa.dupeZ(u8, tp) catch return blockReason(gpa, statsErr())) catch {};
    }
    // Passthrough flags from the remaining tokens.
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "--share") or std.mem.eql(u8, tok, "--all")) {
            args.append(gpa, gpa.dupeZ(u8, tok) catch continue) catch {};
        } else if (std.mem.eql(u8, tok, "--since")) {
            if (it.next()) |val| {
                args.append(gpa, gpa.dupeZ(u8, "--since") catch continue) catch {};
                args.append(gpa, gpa.dupeZ(u8, val) catch continue) catch {};
            }
        }
    }

    const out = captureStdout(gpa, args.items) orelse return blockReason(gpa, statsErr());
    defer gpa.free(out);
    return blockReason(gpa, std.mem.trim(u8, out, " \t\r\n"));
}

fn statsErr() []const u8 {
    return TOOL ++ "-stats: could not run stats binary.";
}

/// Emit {"decision":"block","reason":<reason>} and return true.
fn blockReason(gpa: std.mem.Allocator, reason: []const u8) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"decision\":\"block\",\"reason\":\"") catch return true;
    appendJsonString(gpa, &out, reason) catch return true;
    out.appendSlice(gpa, "\"}") catch return true;
    writeStdout(out.items);
    return true;
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
        anyOrdered(prompt, verbs, TOOL) or
        anyPairOrdered(prompt, &.{TOOL}, verbs);
}

fn parseNaturalActivation(prompt: []const u8, default_mode: []const u8) ?ModeChange {
    const before_tool = &.{ "activate", "enable", "turn on", "start", "talk like" };
    const after_tool = &.{ "mode", "activate", "enable", "turn on", "start" };
    if (anyOrdered(prompt, before_tool, TOOL) or
        anyPairOrdered(prompt, &.{TOOL}, after_tool) or
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
    if (parseSlashMode(prompt, default_mode)) |change| return change;
    if (parseDeactivation(prompt)) return .deactivate;
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

    // /caveman-stats: block the prompt + inject stats output. Checked first,
    // mirroring caveman-mode-tracker.js (the stats handler runs before any
    // mode-change / reinforcement logic). Returns true if it handled the prompt.
    if (handleStats(gpa, prompt, input)) return;

    const default_mode = getDefaultMode(gpa);

    // Silent-fail if env is missing/invalid (e.g. no HOME) — a hook must never
    // bubble an error out of main and disturb prompt submission.
    const path = flagPath(gpa) catch return;
    defer gpa.free(path);

    // 1. Apply a mode change (slash / natural language), if any. This may write
    //    or clear the flag. An ordinary prompt makes parseModeChange null — we
    //    DO NOT return here: per-turn reinforcement below still runs so caveman
    //    stays in the model's attention every turn (mirrors caveman-mode-tracker.js).
    if (parseModeChange(prompt, default_mode)) |change| {
        switch (change) {
            .deactivate => {
                unlinkFlag(path);
                return; // deactivation: nothing to reinforce
            },
            .activate => |mode| safeWriteFlag(gpa, path, mode) catch {}, // silent-fail on FS errors
        }
    }

    // 2. Per-turn reinforcement: read the active flag (symlink-safe, whitelist)
    //    and emit the structured reminder on EVERY turn while caveman is active,
    //    skipping independent modes (commit/review/compress). Byte-for-text match
    //    with the JS hook so other plugins' competing style instructions don't
    //    drown caveman out mid-conversation.
    // readFlagMode returns a borrowed slice into VALID_MODES rodata — do NOT free.
    const active = common.readFlagMode(gpa, path) orelse return;
    if (isIndependentMode(active)) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"");
    try out.appendSlice(gpa, TOOL_UPPER);
    try out.appendSlice(gpa, " MODE ACTIVE (");
    try out.appendSlice(gpa, active);
    try out.appendSlice(gpa, "). Drop articles/filler/pleasantries/hedging. Fragments OK. Code/commits/security: write normal.\"}}");
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
    const activate_phrase = if (std.mem.eql(u8, TOOL, "caveman")) "please talk like caveman now" else "please talk like ponytail now";
    const stop_phrase = if (std.mem.eql(u8, TOOL, "caveman")) "turn off caveman" else "turn off ponytail";
    const stop_talking_phrase = if (std.mem.eql(u8, TOOL, "caveman")) "stop talking like caveman" else "stop talking like ponytail";
    const off_phrase = if (std.mem.eql(u8, TOOL, "caveman")) "activate caveman" else "activate ponytail";
    try expectActivate("lite", activate_phrase, "lite");
    try expectActivate("ultra", "LESS TOKENS please", "ultra");
    try expectDeactivate("normal mode", "full");
    try expectDeactivate(stop_phrase, "full");
    try expectDeactivate(stop_talking_phrase, "full");
    try std.testing.expect(parseModeChange(off_phrase, "off") == null);
}

test "parseModeChange parses slash commands before natural deactivation" {
    const prompt = "/" ++ TOOL ++ " ultra then stop " ++ TOOL;
    try expectActivate("ultra", prompt, "full");
}

test "extractPrompt pulls prompt field" {
    const gpa = std.testing.allocator;
    const got = extractPrompt(gpa, "{\"prompt\":\"/" ++ TOOL ++ " ultra\",\"x\":1}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/" ++ TOOL ++ " ultra", got);
    try std.testing.expect(extractPrompt(gpa, "not json") == null);
}
