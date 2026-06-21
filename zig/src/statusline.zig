//! Caveman/Ponytail statusline badge — Zig 0.16 PoC.
//!
//! Port of src/hooks/caveman-statusline.sh (and .ps1). Reads the mode flag
//! file at $CLAUDE_CONFIG_DIR/.<tool>-active and prints a colored badge to
//! stdout for the Claude Code statusline:
//!
//!   - flag absent / not readable / not a whitelisted mode → print nothing.
//!   - mode "full" (or empty) → "\033[38;5;172m[CAVEMAN]\033[0m"
//!   - any other valid mode   → "\033[38;5;172m[CAVEMAN:<MODE_UPPER>]\033[0m"
//!
//! Then, unless CAVEMAN_STATUSLINE_SAVINGS=0, appends the pre-rendered
//! lifetime-savings suffix (written by caveman-stats.js) with control bytes
//! stripped.
//!
//! Security parity with the shell/PowerShell versions:
//!   - refuse symlinks at the flag and suffix paths (O_NOFOLLOW + lstat).
//!   - cap the read at 64 bytes.
//!   - whitelist-validate the mode; render nothing for junk rather than echo
//!     attacker-controlled bytes (terminal-escape / OSC-hyperlink injection).
//!   - strip control bytes from the savings suffix.
//!
//! Cross-platform: pure libc, no shell-out. Never errors — silent on anomaly.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const c = std.c;

const TOOL = common.TOOL;

const ORANGE_ON = "\x1b[38;5;172m";
const RESET = "\x1b[0m";

/// Strip every byte outside [a-z0-9-] after lowercasing — mirrors the shell's
/// `tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'`. Returns a slice into `buf`.
fn sanitizeMode(buf: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    for (raw) |b0| {
        const b = std.ascii.toLower(b0);
        const keep = (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-';
        if (keep) {
            buf[n] = b;
            n += 1;
            if (n == buf.len) break;
        }
    }
    return buf[0..n];
}

/// Read up to 64 bytes of the flag (O_NOFOLLOW), strip CR/LF, sanitize, and
/// whitelist-validate. Returns the canonical mode or null. Matches statusline.sh:
/// head -c 64 | tr -d '\n\r' | lower | tr -cd 'a-z0-9-', then whitelist.
fn readModeForBadge(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (common.isSymlink(io, path)) return null;
    if (!common.isRegularFileNoSymlink(io, path)) return null;
    const raw = common.readFileAlloc(io, gpa, path, common.MAX_FLAG_BYTES) orelse return null;
    defer gpa.free(raw);

    // Drop CR/LF first (tr -d '\n\r'), then sanitize the rest.
    var nolf: [common.MAX_FLAG_BYTES]u8 = undefined;
    var m: usize = 0;
    for (raw) |b| {
        if (b == '\n' or b == '\r') continue;
        if (m == nolf.len) break;
        nolf[m] = b;
        m += 1;
    }
    var sbuf: [common.MAX_FLAG_BYTES]u8 = undefined;
    const sanitized = sanitizeMode(&sbuf, nolf[0..m]);
    return common.canonicalMode(sanitized);
}

/// Append the savings suffix if enabled and present. Mirrors statusline.sh:
/// CAVEMAN_STATUSLINE_SAVINGS != "0" → read .<tool>-statusline-suffix (refuse
/// symlink, cap 64 bytes, strip control bytes 0x00-0x1F), render with a leading
/// space if non-empty.
fn appendSavings(io: std.Io, out: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    if (common.getenv("CAVEMAN_STATUSLINE_SAVINGS")) |v| {
        if (std.mem.eql(u8, v, "0")) return;
    }
    const path = common.claudeConfigFile(gpa, common.STATUSLINE_SUFFIX_NAME) catch return;
    defer gpa.free(path);

    if (common.isSymlink(io, path)) return;
    if (!common.isRegularFileNoSymlink(io, path)) return;
    const raw = common.readFileAlloc(io, gpa, path, common.MAX_FLAG_BYTES) orelse return;
    defer gpa.free(raw);

    // Strip control bytes 0x00-0x1F (matches tr -d '\000-\037').
    var cleaned: [common.MAX_FLAG_BYTES]u8 = undefined;
    var n: usize = 0;
    for (raw) |b| {
        if (b < 0x20) continue;
        if (n == cleaned.len) break;
        cleaned[n] = b;
        n += 1;
    }
    if (n == 0) return;

    out.appendSlice(gpa, " ") catch return;
    out.appendSlice(gpa, ORANGE_ON) catch return;
    out.appendSlice(gpa, cleaned[0..n]) catch return;
    out.appendSlice(gpa, RESET) catch return;
}

/// Build the badge string for `mode` into `out`. `mode` must already be a
/// canonical whitelisted value. Empty or "full" → [CAVEMAN]; else [CAVEMAN:UP].
fn renderBadge(out: *std.ArrayList(u8), gpa: std.mem.Allocator, mode: []const u8) !void {
    try out.appendSlice(gpa, ORANGE_ON);
    if (mode.len == 0 or std.mem.eql(u8, mode, "full")) {
        try out.appendSlice(gpa, "[CAVEMAN]");
    } else {
        try out.appendSlice(gpa, "[CAVEMAN:");
        for (mode) |b| try out.append(gpa, std.ascii.toUpper(b));
        try out.append(gpa, ']');
    }
    try out.appendSlice(gpa, RESET);
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = common.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    const path = common.flagPath(gpa) catch return; // no HOME → nothing
    defer gpa.free(path);

    const mode = readModeForBadge(io, gpa, path) orelse return; // junk/absent → nothing

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try renderBadge(&out, gpa, mode);
    appendSavings(io, &out, gpa);

    // Stdout is a stream (not seekable), so use the portable streaming write off
    // std.Io.File.stdout() rather than a raw libc c.write(1, …). On Windows the
    // libc write() fd arg is a pointer type (fd_t == *anyopaque), so the literal
    // `1` in common.writeStdout fails the x86_64-windows-gnu cross-compile; the
    // std.Io path resolves stdout from the PEB on Windows and STDOUT_FILENO on
    // POSIX. Silent on anomaly, matching the prior behavior.
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(common);
}

test "renderBadge full vs named mode" {
    const gpa = std.testing.allocator;
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try renderBadge(&out, gpa, "full");
        try std.testing.expectEqualStrings("\x1b[38;5;172m[CAVEMAN]\x1b[0m", out.items);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try renderBadge(&out, gpa, "ultra");
        try std.testing.expectEqualStrings("\x1b[38;5;172m[CAVEMAN:ULTRA]\x1b[0m", out.items);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try renderBadge(&out, gpa, "wenyan-ultra");
        try std.testing.expectEqualStrings("\x1b[38;5;172m[CAVEMAN:WENYAN-ULTRA]\x1b[0m", out.items);
    }
    {
        // Empty → [CAVEMAN] (same as full), mirroring the shell.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try renderBadge(&out, gpa, "");
        try std.testing.expectEqualStrings("\x1b[38;5;172m[CAVEMAN]\x1b[0m", out.items);
    }
}

test "sanitizeMode strips junk and control bytes" {
    var buf: [common.MAX_FLAG_BYTES]u8 = undefined;
    try std.testing.expectEqualStrings("ultra", sanitizeMode(&buf, "ULTRA"));
    try std.testing.expectEqualStrings("wenyan-full", sanitizeMode(&buf, "WenYan-Full"));
    // Escape/OSC injection attempt → only [a-z0-9-] survive (digits in the
    // escape sequence survive too, exactly like the shell's tr -cd 'a-z0-9-').
    try std.testing.expectEqualStrings("31mred0m", sanitizeMode(&buf, "\x1b[31mRED\x1b[0m"));
    try std.testing.expectEqualStrings("", sanitizeMode(&buf, "  \n\t "));
}

test "readModeForBadge whitelist + symlink + control-byte handling" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir_path = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir_path);

    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".sl-active" });
    defer gpa.free(flag);

    // Valid, uppercase, with trailing newline → canonical.
    try common.writeSmall(io, flag, "ULTRA\n");
    try std.testing.expectEqualStrings("ultra", readModeForBadge(io, gpa, flag).?);

    // Junk → null (render nothing, don't echo attacker bytes).
    common.unlinkFlag(io, flag);
    try common.writeSmall(io, flag, "\x1b]8;;http://evil\x07click");
    try std.testing.expect(readModeForBadge(io, gpa, flag) == null);

    // Embedded control bytes inside an otherwise-valid mode are stripped, so
    // "ful\x07l" sanitizes to "full" and validates.
    common.unlinkFlag(io, flag);
    try common.writeSmall(io, flag, "ful\x07l");
    try std.testing.expectEqualStrings("full", readModeForBadge(io, gpa, flag).?);

    // Symlink → null (refused).
    if (builtin.os.tag == .windows) return;
    common.unlinkFlag(io, flag);
    const target = try std.fs.path.join(gpa, &.{ dir_path, "secret.txt" });
    defer gpa.free(target);
    try common.writeSmall(io, target, "full");
    std.Io.Dir.cwd().symLink(io, target, flag, .{}) catch return error.SkipZigTest;
    try std.testing.expect(readModeForBadge(io, gpa, flag) == null);

    common.unlinkFlag(io, flag);
    common.unlinkFlag(io, target);
}
