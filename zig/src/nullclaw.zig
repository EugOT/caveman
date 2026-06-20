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
    gpa: std.mem.Allocator,
    workspace: []const u8,
    skill_body: []const u8,
    dry_run: bool,
    force: bool,
) !InstallResult {
    if (common.classify(workspace) == .missing) {
        if (!force) return .{ .ok = false, .reason = "workspace missing" };
        if (!dry_run) mkdirP(workspace);
    } else if (common.classify(workspace) == .symlink or common.classify(workspace) == .other) {
        return .{ .ok = false, .reason = "unsafe target" };
    }

    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    const skill_file = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_file);

    if (common.isSymlink(skill_file)) return .{ .ok = false, .reason = "unsafe target" };
    if (common.classify(skill_dir) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    {
        const skills_parent = try std.fs.path.join(gpa, &.{ workspace, "skills" });
        defer gpa.free(skills_parent);
        if (common.classify(skills_parent) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    }
    {
        const sd = std.fs.path.dirname(skill_file) orelse skill_dir;
        if (common.ancestorUnsafe(sd)) return .{ .ok = false, .reason = "unsafe target" };
    }

    if (dry_run) return .{ .ok = true };

    // skills/caveman/ is two levels under the workspace; common.safeWriteFlag
    // only mkdirs the immediate parent, so create the tree first.
    mkdirP(skill_dir);

    const merged = try openclaw.mergeOpenclawFrontmatter(gpa, skill_body);
    defer gpa.free(merged);
    common.safeWriteFlag(gpa, skill_file, merged) catch return .{ .ok = false, .reason = "unsafe target" };
    return .{ .ok = true };
}

/// JS uninstallNullclaw: remove only the skill folder (SOUL.md untouched).
pub fn uninstallNullclaw(gpa: std.mem.Allocator, workspace: []const u8, dry_run: bool) !void {
    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    if (common.classify(skill_dir) != .missing and !dry_run) {
        openclaw.removeTree(gpa, skill_dir);
    }
}

// ── Filesystem helpers (libc) ───────────────────────────────────────────────
fn mkdirP(dir: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= buf.len) return;
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
}

// removeTree is shared via openclaw.removeTree (libc opendir/readdir + lstat).

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
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "null-ws" });
    defer gpa.free(ws);
    try common.mkdirPath(ws);

    const skill_body = "---\ndescription: x\n---\nRespond terse like smart caveman.\n";

    const r1 = try installNullclaw(gpa, ws, skill_body, false, false);
    try testing.expect(r1.ok);

    const skill_file = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman", "SKILL.md" });
    defer gpa.free(skill_file);
    const raw = common.readFileAlloc(gpa, skill_file, 1 << 20).?;
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "name: caveman") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "always: true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "Respond terse like smart caveman") != null);

    // idempotent re-run keeps exactly one always: key
    const r2 = try installNullclaw(gpa, ws, skill_body, false, false);
    try testing.expect(r2.ok);
    const raw2 = common.readFileAlloc(gpa, skill_file, 1 << 20).?;
    defer gpa.free(raw2);
    try testing.expectEqual(@as(usize, 1), countOccurrences(raw2, "always: true"));

    // SOUL.md must NOT be written by nullclaw (unlike openclaw)
    const soul = try std.fs.path.join(gpa, &.{ ws, "SOUL.md" });
    defer gpa.free(soul);
    try testing.expect(common.classify(soul) == .missing);

    // uninstall removes only the skill folder
    try uninstallNullclaw(gpa, ws, false);
    const skill_dir = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman" });
    defer gpa.free(skill_dir);
    try testing.expect(common.classify(skill_dir) == .missing);
}

test "installNullclaw reports workspace missing without force" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "no-ws" });
    defer gpa.free(ws);

    const skill_body = "---\ndescription: x\n---\nbody\n";
    const r = try installNullclaw(gpa, ws, skill_body, false, false);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("workspace missing", r.reason);
}

test "installNullclaw refuses symlinked skill target" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "null-ws2" });
    defer gpa.free(ws);
    const skill_dir = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman" });
    defer gpa.free(skill_dir);
    try common.mkdirPath(ws);
    {
        const skills = try std.fs.path.join(gpa, &.{ ws, "skills" });
        defer gpa.free(skills);
        try common.mkdirPath(skills);
        try common.mkdirPath(skill_dir);
    }

    const outside = try std.fs.path.join(gpa, &.{ dir_path, "outside.md" });
    defer gpa.free(outside);
    try common.writeSmall(outside, "outside stays\n");

    const skill_file = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_file);
    var ob: [std.fs.max_path_bytes]u8 = undefined;
    var sb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(c.symlink(try common.toZ(&ob, outside), try common.toZ(&sb, skill_file)) == 0);

    const r = try installNullclaw(gpa, ws, "---\nx: y\n---\nbody\n", false, false);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("unsafe target", r.reason);
    const data = try common.readSmall(gpa, outside);
    defer gpa.free(data);
    try testing.expectEqualStrings("outside stays\n", data);

    _ = c.unlink(try common.toZ(&sb, skill_file));
    _ = c.unlink(try common.toZ(&ob, outside));
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
