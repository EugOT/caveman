//! caveman → NullClaw install / uninstall helper — Zig 0.16 port of
//! bin/lib/nullclaw.js (R4b stage 1).
//!
//! NullClaw loads user skills from $NULLCLAW_WORKSPACE/skills/<name>/,
//! $NULLCLAW_HOME/workspace/skills/<name>/, or ~/.nullclaw/workspace/skills/<name>/.
//! A SKILL.md with `always: true` frontmatter becomes part of the system prompt,
//! the closest NullClaw-native match for caveman's always-on behavior.
//!
//! This is a MODULE imported by the installer port (stage 2). It reuses the
//! openclaw frontmatter merge (mergeOpenclawFrontmatter) and common.zig safe
//! writes. libc C-ABI throughout (std.c).

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const openclaw = @import("openclaw.zig");
const c = std.c;

pub const SKILL_NAME = "caveman";

pub const Error = openclaw.Error;

/// JS resolveWorkspace:
///   $NULLCLAW_WORKSPACE (resolved) →
///   ($NULLCLAW_HOME (resolved) else ~/.nullclaw)/workspace.
/// Caller owns the returned slice.
pub fn resolveWorkspace(gpa: std.mem.Allocator) Error![]u8 {
    if (common.getenv("NULLCLAW_WORKSPACE")) |ws| {
        return resolveAbs(gpa, ws);
    }
    if (common.getenv("NULLCLAW_HOME")) |home| {
        const home_abs = try resolveAbs(gpa, home);
        defer gpa.free(home_abs);
        return std.fs.path.join(gpa, &.{ home_abs, "workspace" });
    }
    const home = common.getenv("HOME") orelse return error.PathTooLong;
    return std.fs.path.join(gpa, &.{ home, ".nullclaw", "workspace" });
}

fn resolveAbs(gpa: std.mem.Allocator, p: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(p)) return gpa.dupe(u8, p);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return gpa.dupe(u8, p);
    const cwd = std.mem.sliceTo(cwd_z, 0);
    return std.fs.path.resolve(gpa, &.{ cwd, p });
}

pub const InstallResult = openclaw.InstallResult;

/// JS installNullclaw. Writes the always-on skill into the resolved workspace.
///   - `workspace`: target workspace dir (caller resolves; use resolveWorkspace).
///   - `skill_body`: raw skills/caveman/SKILL.md bytes (embedded or read).
///   - `dry_run`: when true, perform no writes.
///   - `force`: when true, mkdir the workspace if missing.
/// Mirrors the ordering, safety checks, and return reasons of the JS.
pub fn installNullclaw(
    io: std.Io,
    gpa: std.mem.Allocator,
    workspace: []const u8,
    skill_body: []const u8,
    dry_run: bool,
    force: bool,
) !InstallResult {
    if (common.classify(io, workspace) == .missing) {
        if (!force) return .{ .ok = false, .reason = "workspace missing" };
        if (!dry_run and !mkdirP(io, workspace)) return .{ .ok = false, .reason = "unsafe target" };
    } else if (common.classify(io, workspace) == .symlink or common.classify(io, workspace) == .other) {
        return .{ .ok = false, .reason = "unsafe target" };
    }

    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    const skill_file = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_file);

    if (common.isSymlink(io, skill_file)) return .{ .ok = false, .reason = "unsafe target" };
    if (common.classify(io, skill_dir) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    {
        const skills_parent = try std.fs.path.join(gpa, &.{ workspace, "skills" });
        defer gpa.free(skills_parent);
        if (common.classify(io, skills_parent) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    }
    {
        const sd = std.fs.path.dirname(skill_file) orelse skill_dir;
        if (common.ancestorUnsafe(io, sd)) return .{ .ok = false, .reason = "unsafe target" };
    }

    if (dry_run) return .{ .ok = true };

    // skills/caveman/ is two levels under the workspace; common.safeWriteFlag
    // only mkdirs the immediate parent, so create the tree first.
    if (!mkdirP(io, skill_dir)) return .{ .ok = false, .reason = "unsafe target" };

    const merged = try openclaw.mergeOpenclawFrontmatter(gpa, skill_body);
    defer gpa.free(merged);
    common.safeWriteFlag(io, gpa, skill_file, merged) catch return .{ .ok = false, .reason = "unsafe target" };
    return .{ .ok = true };
}

/// JS uninstallNullclaw: remove only the skill folder (SOUL.md untouched).
pub fn uninstallNullclaw(io: std.Io, gpa: std.mem.Allocator, workspace: []const u8, dry_run: bool) !void {
    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    if (common.classify(io, skill_dir) == .dir and !dry_run) {
        openclaw.removeTree(io, gpa, skill_dir);
    }
}

// ── Filesystem helpers (libc) ───────────────────────────────────────────────
fn mkdirP(io: std.Io, dir: []const u8) bool {
    if (common.ancestorUnsafe(io, dir)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= buf.len) return false;
    var i: usize = 0;
    while (i < dir.len) {
        var j = i;
        while (j < dir.len and dir[j] != std.fs.path.sep) j += 1;
        const prefix = dir[0..j];
        if (prefix.len > 0) {
            @memcpy(buf[0..prefix.len], prefix);
            buf[prefix.len] = 0;
            _ = c.mkdir(@ptrCast(buf[0..prefix.len :0].ptr), 0o755);
        }
        i = j + 1;
    }
    return common.classify(io, dir) == .dir;
}

// removeTree is shared via openclaw.removeTree (libc opendir/readdir + std.Io classify).

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "resolveWorkspace honors NULLCLAW_WORKSPACE first" {
    const gpa = testing.allocator;
    const old_ws = try common.saveEnv(gpa, "NULLCLAW_WORKSPACE");
    defer if (old_ws) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_WORKSPACE", old_ws);
    const old_home = try common.saveEnv(gpa, "NULLCLAW_HOME");
    defer if (old_home) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_HOME", old_home);

    _ = common.setenv("NULLCLAW_WORKSPACE", "/tmp/null-ws", 1);
    _ = common.setenv("NULLCLAW_HOME", "/tmp/null-home", 1);
    const ws = try resolveWorkspace(gpa);
    defer gpa.free(ws);
    try testing.expectEqualStrings("/tmp/null-ws", ws); // WORKSPACE wins
}

test "resolveWorkspace falls back to NULLCLAW_HOME/workspace" {
    const gpa = testing.allocator;
    const old_ws = try common.saveEnv(gpa, "NULLCLAW_WORKSPACE");
    defer if (old_ws) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_WORKSPACE", old_ws);
    const old_home = try common.saveEnv(gpa, "NULLCLAW_HOME");
    defer if (old_home) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_HOME", old_home);

    _ = common.unsetenv("NULLCLAW_WORKSPACE");
    _ = common.setenv("NULLCLAW_HOME", "/tmp/null-home", 1);
    const ws = try resolveWorkspace(gpa);
    defer gpa.free(ws);
    try testing.expectEqualStrings("/tmp/null-home/workspace", ws);
}

test "resolveWorkspace falls back to ~/.nullclaw/workspace" {
    const gpa = testing.allocator;
    const old_ws = try common.saveEnv(gpa, "NULLCLAW_WORKSPACE");
    defer if (old_ws) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_WORKSPACE", old_ws);
    const old_home = try common.saveEnv(gpa, "NULLCLAW_HOME");
    defer if (old_home) |v| gpa.free(v);
    defer common.restoreEnv("NULLCLAW_HOME", old_home);
    const old_h = try common.saveEnv(gpa, "HOME");
    defer if (old_h) |v| gpa.free(v);
    defer common.restoreEnv("HOME", old_h);

    _ = common.unsetenv("NULLCLAW_WORKSPACE");
    _ = common.unsetenv("NULLCLAW_HOME");
    _ = common.setenv("HOME", "/tmp/fake-home", 1);
    const ws = try resolveWorkspace(gpa);
    defer gpa.free(ws);
    try testing.expectEqualStrings("/tmp/fake-home/.nullclaw/workspace", ws);
}

test "installNullclaw writes always-on skill, idempotent, uninstall removes folder" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "null-ws" });
    defer gpa.free(ws);
    try common.mkdirPath(io, ws);

    const skill_body = "---\ndescription: x\n---\nRespond terse like smart caveman.\n";

    const r1 = try installNullclaw(io, gpa, ws, skill_body, false, false);
    try testing.expect(r1.ok);

    const skill_file = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman", "SKILL.md" });
    defer gpa.free(skill_file);
    const raw = common.readFileAlloc(io, gpa, skill_file, 1 << 20).?;
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "name: caveman") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "always: true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "Respond terse like smart caveman") != null);

    // idempotent re-run keeps exactly one always: key
    const r2 = try installNullclaw(io, gpa, ws, skill_body, false, false);
    try testing.expect(r2.ok);
    const raw2 = common.readFileAlloc(io, gpa, skill_file, 1 << 20).?;
    defer gpa.free(raw2);
    try testing.expectEqual(@as(usize, 1), countOccurrences(raw2, "always: true"));

    // SOUL.md must NOT be written by nullclaw (unlike openclaw)
    const soul = try std.fs.path.join(gpa, &.{ ws, "SOUL.md" });
    defer gpa.free(soul);
    try testing.expect(common.classify(io, soul) == .missing);

    // uninstall removes only the skill folder
    try uninstallNullclaw(io, gpa, ws, false);
    const skill_dir = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman" });
    defer gpa.free(skill_dir);
    try testing.expect(common.classify(io, skill_dir) == .missing);
}

test "installNullclaw reports workspace missing without force" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "no-ws" });
    defer gpa.free(ws);

    const skill_body = "---\ndescription: x\n---\nbody\n";
    const r = try installNullclaw(io, gpa, ws, skill_body, false, false);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("workspace missing", r.reason);
}

test "installNullclaw refuses symlinked skill target" {
    if (builtin.os.tag == .windows) return;
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "null-ws2" });
    defer gpa.free(ws);
    const skill_dir = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman" });
    defer gpa.free(skill_dir);
    try common.mkdirPath(io, ws);
    {
        const skills = try std.fs.path.join(gpa, &.{ ws, "skills" });
        defer gpa.free(skills);
        try common.mkdirPath(io, skills);
        try common.mkdirPath(io, skill_dir);
    }

    const outside = try std.fs.path.join(gpa, &.{ dir_path, "outside.md" });
    defer gpa.free(outside);
    try common.writeSmall(io, outside, "outside stays\n");

    const skill_file = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_file);
    std.Io.Dir.cwd().symLink(io, outside, skill_file, .{}) catch return error.SkipZigTest;

    const r = try installNullclaw(io, gpa, ws, "---\nx: y\n---\nbody\n", false, false);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("unsafe target", r.reason);
    const data = try common.readSmall(io, gpa, outside);
    defer gpa.free(data);
    try testing.expectEqualStrings("outside stays\n", data);

    common.unlinkFlag(io, skill_file);
    common.unlinkFlag(io, outside);
}

test "uninstallNullclaw skips symlinked skill directory" {
    if (builtin.os.tag == .windows) return;
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "null-ws3" });
    defer gpa.free(ws);
    const skills = try std.fs.path.join(gpa, &.{ ws, "skills" });
    defer gpa.free(skills);
    try common.mkdirPath(io, ws);
    try common.mkdirPath(io, skills);

    const outside = try std.fs.path.join(gpa, &.{ dir_path, "outside-skill" });
    defer gpa.free(outside);
    try common.mkdirPath(io, outside);
    const marker = try std.fs.path.join(gpa, &.{ outside, "marker.txt" });
    defer gpa.free(marker);
    try common.writeSmall(io, marker, "keep\n");

    const skill_dir = try std.fs.path.join(gpa, &.{ skills, "caveman" });
    defer gpa.free(skill_dir);
    std.Io.Dir.cwd().symLink(io, outside, skill_dir, .{}) catch return error.SkipZigTest;

    try uninstallNullclaw(io, gpa, ws, false);
    try testing.expect(common.classify(io, skill_dir) == .symlink);
    const data = try common.readSmall(io, gpa, marker);
    defer gpa.free(data);
    try testing.expectEqualStrings("keep\n", data);

    common.unlinkFlag(io, skill_dir);
    common.unlinkFlag(io, marker);
    std.Io.Dir.cwd().deleteDir(io, outside) catch {};
}

fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, hay, idx, needle)) |pos| {
        n += 1;
        idx = pos + needle.len;
    }
    return n;
}
