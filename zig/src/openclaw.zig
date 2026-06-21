//! caveman → OpenClaw install / uninstall helper — Zig 0.16 port of
//! bin/lib/openclaw.js (R4b stage 1).
//!
//! OpenClaw is a self-hosted gateway. To make caveman always-on through it we
//! do two writes into a workspace dir:
//!   1. Drop skills/caveman/SKILL.md (with `name`/`version`/`always:true`
//!      frontmatter merged in) into <workspace>/skills/caveman/SKILL.md.
//!   2. Append a marker-fenced bootstrap snippet to <workspace>/SOUL.md.
//!      SOUL.md is auto-injected each turn, so this drives always-on behavior.
//!
//! Both writes are idempotent. Uninstall removes the skill folder and strips
//! the marker block from SOUL.md while preserving user-authored content.
//!
//! This is a MODULE imported by the installer port (stage 2). It is pure logic
//! + libc C-ABI filesystem calls (std.c), matching the rest of the Zig hook
//! tree. All durable writes go through common.safeWriteFlag (symlink-safe,
//! atomic temp+rename, refuse-on-symlink target + ancestor).
//!
//! Byte-exactness with the JS is load-bearing: OpenClaw idempotency keys off the
//! SENTINEL `Respond terse like smart caveman` and the begin/end markers, so the
//! frontmatter merge, SOUL append/strip, and bootstrap snippet are all mirrored
//! exactly.

const std = @import("std");
const common = @import("common.zig");
const c = std.c;

pub const SKILL_NAME = "caveman";
pub const SKILL_VERSION = "1.0.0";
pub const MARK_BEGIN = "<!-- caveman-begin -->";
pub const MARK_END = "<!-- caveman-end -->";
pub const SOUL_FILE = "SOUL.md";
pub const SENTINEL = "Respond terse like smart caveman";

/// Standalone-fallback bootstrap snippet. Byte-equivalent to
/// src/rules/caveman-openclaw-bootstrap.md run through loadBootstrapSnippet's
/// trailing-newline normalization (`body.endsWith('\n') ? body : body + '\n'`).
/// The JS embeds this same fallback inline; we keep it here so callers without
/// a repo on disk still get a byte-identical SOUL.md block.
pub const BOOTSTRAP_SNIPPET =
    MARK_BEGIN ++ "\n" ++
    "## Caveman mode (always on)\n" ++
    "\n" ++
    "Respond terse like smart caveman. All technical substance stay. Only fluff die.\n" ++
    "\n" ++
    "The full ruleset and intensity levels live in this workspace's caveman skill:\n" ++
    "\n" ++
    "  skills/caveman/SKILL.md\n" ++
    "\n" ++
    "Default intensity: `full`. Switch with `/caveman lite|full|ultra|wenyan`.\n" ++
    "Stop with: \"stop caveman\" / \"normal mode\" / \"deactivate caveman\".\n" ++
    "\n" ++
    "Auto-Clarity: drop caveman for security warnings, irreversible action\n" ++
    "confirmations, multi-step sequences where fragments risk misread, or when\n" ++
    "user is confused or repeating. Resume after.\n" ++
    "\n" ++
    "Boundaries: code, commit messages, and PR descriptions stay normal prose.\n" ++
    MARK_END ++ "\n";

pub const Error = error{
    SymlinkRefused,
    UnsafeParent,
    UnsafeTarget,
    OpenFailed,
    WriteFailed,
    RenameFailed,
    PathTooLong,
} || std.mem.Allocator.Error;

// ── Workspace resolution ────────────────────────────────────────────────────
// JS: resolveWorkspace — $OPENCLAW_WORKSPACE (resolved) else ~/.openclaw/workspace.
// Caller owns the returned slice.
pub fn resolveWorkspace(gpa: std.mem.Allocator) Error![]u8 {
    if (common.getenv("OPENCLAW_WORKSPACE")) |ws| {
        return resolveAbs(gpa, ws);
    }
    const home = common.getenv("HOME") orelse return error.PathTooLong;
    return std.fs.path.join(gpa, &.{ home, ".openclaw", "workspace" });
}

fn resolveAbs(gpa: std.mem.Allocator, p: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(p)) return gpa.dupe(u8, p);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return gpa.dupe(u8, p);
    const cwd = std.mem.sliceTo(cwd_z, 0);
    return std.fs.path.resolve(gpa, &.{ cwd, p });
}

// ── Frontmatter helpers (byte-exact mirror of openclaw.js) ──────────────────
pub const Split = struct {
    frontmatter: []const u8,
    body: []const u8,
};

/// JS splitFrontmatter. Returns slices INTO `src` (no allocation). If `src` has
/// no leading `---\n` (or `---\r\n`) fence, or no closing `---` line, returns
/// `{ frontmatter: "", body: src }`.
pub fn splitFrontmatter(src: []const u8) Split {
    if (!std.mem.startsWith(u8, src, "---\n") and !std.mem.startsWith(u8, src, "---\r\n")) {
        return .{ .frontmatter = "", .body = src };
    }
    // after = src.slice(src.indexOf('\n') + 1)
    const first_nl = std.mem.indexOfScalar(u8, src, '\n') orelse return .{ .frontmatter = "", .body = src };
    const after = src[first_nl + 1 ..];

    // endRe = /(^|\n)---\s*(\r?\n|$)/  — find the closing fence in `after`.
    const m = findEndFence(after) orelse return .{ .frontmatter = "", .body = src };
    // m.index is the match start (relative to `after`); group1 ("^"|"\n") width
    // is 0 if at start, else 1. fmEnd = m.index + (group1 ? 1 : 0).
    const fm_end = m.index + (if (m.has_leading_nl) @as(usize, 1) else 0);
    const fm = after[0..fm_end];
    const rest = after[m.index + m.len ..];
    return .{ .frontmatter = fm, .body = rest };
}

const FenceMatch = struct {
    index: usize, // start of the (^|\n) group within `after`
    len: usize, // total match length, incl. leading \n + "---" + \s* + (\r?\n|$)
    has_leading_nl: bool, // whether group1 matched "\n" (vs start-of-string "^")
};

/// Emulate JS regex /(^|\n)---\s*(\r?\n|$)/.exec(after) — leftmost match.
fn findEndFence(after: []const u8) ?FenceMatch {
    var pos: usize = 0;
    while (pos <= after.len) : (pos += 1) {
        // group1: "^" (only at pos==0) OR a literal "\n" at after[pos-1].
        var dash_start: usize = undefined;
        var has_leading_nl: bool = undefined;
        if (pos == 0) {
            dash_start = 0;
            has_leading_nl = false;
        } else if (after[pos - 1] == '\n') {
            dash_start = pos;
            has_leading_nl = true;
        } else {
            continue;
        }
        // require "---" at dash_start
        if (dash_start + 3 > after.len) continue;
        if (!std.mem.eql(u8, after[dash_start .. dash_start + 3], "---")) continue;
        // \s* — greedy run of whitespace
        var ws_end = dash_start + 3;
        while (ws_end < after.len and isSpace(after[ws_end])) ws_end += 1;
        // (\r?\n|$): backtrack \s* so the \r?\n|$ can match.
        // The JS engine backtracks \s* to let (\r?\n|$) match. Simplest faithful
        // emulation: the \s* greedily consumed up to ws_end; then we need either
        // end-of-string at ws_end, or a position where \r?\n follows. Because \s*
        // ate any trailing \r\n already, end-of-string at ws_end satisfies `$`,
        // and a non-end position can't follow a maximal whitespace run with a
        // newline. So we accept ws_end == after.len ($) OR the run included a
        // newline. The total match length runs through the consumed whitespace
        // run (tail_end == ws_end) in both branches.
        const tail_end = ws_end;
        if (ws_end == after.len) {
            // matches `$`; total match = up to end (group1 + "---" + \s*)
            const match_start = if (has_leading_nl) pos - 1 else pos;
            return .{ .index = match_start, .len = tail_end - match_start, .has_leading_nl = has_leading_nl };
        }
        // Not at end: the closing must include a \r?\n. \s* would have consumed
        // it; JS reports the match through the consumed newline run. Treat the
        // whole whitespace run as part of the match (mirrors how \s* then `$`/\n
        // closes). Require that the run contained at least one '\n'.
        var saw_nl = false;
        var k = dash_start + 3;
        while (k < ws_end) : (k += 1) {
            if (after[k] == '\n') saw_nl = true;
        }
        if (!saw_nl) continue;
        const match_start = if (has_leading_nl) pos - 1 else pos;
        return .{ .index = match_start, .len = tail_end - match_start, .has_leading_nl = has_leading_nl };
    }
    return null;
}

fn isSpace(ch: u8) bool {
    // JS \s: space, \t, \n, \r, \f, \v (and a few unicode we ignore for ASCII fm).
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c or ch == 0x0b;
}

/// JS frontmatterHasKey: /(^|\n)<key>\s*:/i over the frontmatter block.
pub fn frontmatterHasKey(fm: []const u8, key: []const u8) bool {
    var idx: usize = 0;
    while (true) {
        const pos = indexOfKeyCaseInsensitive(fm, key, idx) orelse return false;
        const before_ok = pos == 0 or fm[pos - 1] == '\n';
        if (before_ok) {
            // skip optional \s* then require ':'
            var j = pos + key.len;
            while (j < fm.len and isSpace(fm[j])) j += 1;
            if (j < fm.len and fm[j] == ':') return true;
        }
        idx = pos + 1;
    }
}

fn indexOfKeyCaseInsensitive(hay: []const u8, key: []const u8, from: usize) ?usize {
    if (key.len == 0 or from > hay.len) return null;
    var i = from;
    while (i + key.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + key.len], key)) return i;
    }
    return null;
}

/// JS mergeOpenclawFrontmatter. Returns either a copy of `src` (when nothing to
/// add and frontmatter present) or a freshly built buffer with the missing
/// top-level keys appended. Caller owns the returned slice.
pub fn mergeOpenclawFrontmatter(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const sp = splitFrontmatter(src);

    var additions: std.ArrayList([]const u8) = .empty;
    defer additions.deinit(gpa);
    if (!frontmatterHasKey(sp.frontmatter, "name")) try additions.append(gpa, "name: " ++ SKILL_NAME);
    if (!frontmatterHasKey(sp.frontmatter, "version")) try additions.append(gpa, "version: " ++ SKILL_VERSION);
    if (!frontmatterHasKey(sp.frontmatter, "always")) try additions.append(gpa, "always: true");

    // JS: if (additions.length === 0 && frontmatter) return src;
    if (additions.items.len == 0 and sp.frontmatter.len > 0) {
        return gpa.dupe(u8, src);
    }

    // fmBody = (frontmatter ? frontmatter.trimEnd() + '\n' : '')
    //          + additions.join('\n')
    //          + (additions.length ? '\n' : '')
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "---\n");
    if (sp.frontmatter.len > 0) {
        const trimmed = std.mem.trimEnd(u8, sp.frontmatter, " \t\r\n");
        try out.appendSlice(gpa, trimmed);
        try out.append(gpa, '\n');
    }
    for (additions.items, 0..) |a, i| {
        if (i != 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, a);
    }
    if (additions.items.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, "---\n");
    try out.appendSlice(gpa, sp.body);
    return out.toOwnedSlice(gpa);
}

// ── Bootstrap snippet ───────────────────────────────────────────────────────
/// JS loadBootstrapSnippet: prefer the in-repo file (here: the @embedFile'd
/// source-of-truth, normalized to end with exactly one trailing newline),
/// else the inline fallback. Both are byte-identical in this build because the
/// embedded body IS src/rules/caveman-openclaw-bootstrap.md. Caller owns the
/// returned slice.
pub fn loadBootstrapSnippet(gpa: std.mem.Allocator, repo_body: ?[]const u8) ![]u8 {
    if (repo_body) |body| {
        if (body.len > 0) {
            if (body[body.len - 1] == '\n') return gpa.dupe(u8, body);
            const out = try gpa.alloc(u8, body.len + 1);
            @memcpy(out[0..body.len], body);
            out[body.len] = '\n';
            return out;
        }
    }
    return gpa.dupe(u8, BOOTSTRAP_SNIPPET);
}

// ── SOUL.md marker-block append / strip ─────────────────────────────────────
pub const SoulResult = struct {
    changed: bool,
    removed: bool = false,
    skipped: bool = false,
};

/// JS appendBootstrapToSoul. Idempotent: if SOUL.md already has BOTH markers it
/// returns unchanged. Otherwise appends the snippet with the same separator
/// logic (`endsWith("\n\n") ? "" : endsWith("\n") ? "\n" : "\n\n"`). All writes
/// go through common.safeWriteFlag. `root` is the workspace dir, used for the
/// ancestor-symlink anchor.
pub fn appendBootstrapToSoul(gpa: std.mem.Allocator, soul_path: []const u8, snippet: []const u8) Error!SoulResult {
    if (common.isSymlink(soul_path)) return .{ .changed = false, .skipped = true };
    const dir = std.fs.path.dirname(soul_path) orelse ".";
    if (common.ancestorUnsafe(dir)) return .{ .changed = false, .skipped = true };

    const existing: ?[]u8 = if (common.existsNoFollow(soul_path)) blk: {
        if (!common.isRegularFileNoSymlink(soul_path)) return .{ .changed = false, .skipped = true };
        break :blk common.readFileAlloc(gpa, soul_path, 4 * 1024 * 1024) orelse
            return .{ .changed = false, .skipped = true };
    } else null;
    defer if (existing) |e| gpa.free(e);

    if (existing) |e| {
        if (std.mem.indexOf(u8, e, MARK_BEGIN) != null and std.mem.indexOf(u8, e, MARK_END) != null) {
            return .{ .changed = false };
        }
    }

    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(gpa);
    if (existing) |e| {
        if (e.len > 0) {
            try next.appendSlice(gpa, e);
            const sep = if (std.mem.endsWith(u8, e, "\n\n"))
                ""
            else if (std.mem.endsWith(u8, e, "\n"))
                "\n"
            else
                "\n\n";
            try next.appendSlice(gpa, sep);
            try next.appendSlice(gpa, snippet);
        } else {
            try next.appendSlice(gpa, snippet);
        }
    } else {
        try next.appendSlice(gpa, snippet);
    }

    common.safeWriteFlag(gpa, soul_path, next.items) catch return .{ .changed = false, .skipped = true };
    return .{ .changed = true };
}

/// JS stripBootstrapFromSoul. Removes the marker block, collapsing adjacent
/// blank lines around the cut. If SOUL.md only contained our block, the file is
/// unlinked. Mirrors the `before.replace(/\n+$/, '\n') + after.replace(/^\n+/,
/// '\n')`.trimEnd() reconstruction, then `+ '\n'` when non-empty.
pub fn stripBootstrapFromSoul(gpa: std.mem.Allocator, soul_path: []const u8) Error!SoulResult {
    if (common.isSymlink(soul_path)) return .{ .changed = false, .skipped = true };
    const dir = std.fs.path.dirname(soul_path) orelse ".";
    if (common.ancestorUnsafe(dir)) return .{ .changed = false, .skipped = true };

    if (common.existsNoFollow(soul_path) and !common.isRegularFileNoSymlink(soul_path)) {
        return .{ .changed = false, .skipped = true };
    }
    const existing = common.readFileAlloc(gpa, soul_path, 4 * 1024 * 1024) orelse
        return .{ .changed = false, .skipped = true };
    defer gpa.free(existing);

    const begin = std.mem.indexOf(u8, existing, MARK_BEGIN) orelse return .{ .changed = false };
    const end_pos = std.mem.indexOf(u8, existing, MARK_END) orelse return .{ .changed = false };
    if (end_pos <= begin) return .{ .changed = false };

    const before = existing[0..begin];
    const after = existing[end_pos + MARK_END.len ..];

    // before.replace(/\n+$/, '\n')
    const before_trimmed = replaceTrailingNewlines(before);
    // after.replace(/^\n+/, '\n')
    const after_trimmed = replaceLeadingNewlines(after);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joined.appendSlice(gpa, before_trimmed);
    try joined.appendSlice(gpa, after_trimmed);

    // .trimEnd()
    const trimmed = std.mem.trimEnd(u8, joined.items, " \t\r\n\u{000b}\u{000c}");

    if (trimmed.len == 0) {
        // SOUL.md only contained our block — remove the file.
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (common.toZ(&pbuf, soul_path)) |pz| {
            _ = c.unlink(pz);
        } else |_| {}
        return .{ .changed = true, .removed = true };
    }

    var final: std.ArrayList(u8) = .empty;
    defer final.deinit(gpa);
    try final.appendSlice(gpa, trimmed);
    try final.append(gpa, '\n');

    common.safeWriteFlag(gpa, soul_path, final.items) catch return .{ .changed = false, .skipped = true };
    return .{ .changed = true };
}

// /\n+$/ → '\n': if the slice ends with one-or-more '\n', collapse them to one.
fn replaceTrailingNewlines(s: []const u8) []const u8 {
    if (s.len == 0 or s[s.len - 1] != '\n') return s;
    var i = s.len;
    while (i > 0 and s[i - 1] == '\n') i -= 1;
    // keep one newline → s[0..i+1]
    return s[0 .. i + 1];
}

// /^\n+/ → '\n': if the slice starts with one-or-more '\n', collapse them to one.
fn replaceLeadingNewlines(s: []const u8) []const u8 {
    if (s.len == 0 or s[0] != '\n') return s;
    var i: usize = 0;
    while (i < s.len and s[i] == '\n') i += 1;
    // keep one newline → s[i-1..]
    return s[i - 1 ..];
}

// ── install / uninstall (filesystem, used by the installer port) ────────────
pub const InstallResult = struct {
    ok: bool,
    reason: []const u8 = "",
};

/// Install caveman into an OpenClaw workspace.
///   - `workspace`: target workspace dir (caller resolves; use resolveWorkspace).
///   - `skill_body`: raw skills/caveman/SKILL.md bytes (embedded or read).
///   - `snippet`: the SOUL.md bootstrap snippet (from loadBootstrapSnippet).
///   - `dry_run`: when true, perform no writes.
///   - `force`: when true, mkdir the workspace if missing.
/// Mirrors installOpenclaw's ordering, safety checks, and return reasons.
pub fn installOpenclaw(
    gpa: std.mem.Allocator,
    workspace: []const u8,
    skill_body: []const u8,
    snippet: []const u8,
    dry_run: bool,
    force: bool,
) !InstallResult {
    // Workspace existence + force-mkdir.
    if (common.classify(workspace) == .missing) {
        if (!force) return .{ .ok = false, .reason = "workspace missing" };
        if (!dry_run and !mkdirP(workspace)) return .{ .ok = false, .reason = "unsafe target" };
    } else if (common.classify(workspace) == .symlink or common.classify(workspace) == .other) {
        return .{ .ok = false, .reason = "unsafe target" };
    }

    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    const skill_file = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_file);
    const soul_file = try std.fs.path.join(gpa, &.{ workspace, SOUL_FILE });
    defer gpa.free(soul_file);

    // Safety: refuse symlinked skill file / soul file / parents under workspace.
    if (common.isSymlink(skill_file)) return .{ .ok = false, .reason = "unsafe target" };
    if (common.isSymlink(soul_file)) return .{ .ok = false, .reason = "unsafe target" };
    {
        const sd = std.fs.path.dirname(skill_file) orelse skill_dir;
        if (common.ancestorUnsafe(sd)) return .{ .ok = false, .reason = "unsafe target" };
    }
    // skill_dir must not itself be a symlink if it exists.
    if (common.classify(skill_dir) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    // the `skills` parent dir must not be a symlink either.
    {
        const skills_parent = try std.fs.path.join(gpa, &.{ workspace, "skills" });
        defer gpa.free(skills_parent);
        if (common.classify(skills_parent) == .symlink) return .{ .ok = false, .reason = "unsafe target" };
    }

    if (dry_run) return .{ .ok = true };

    // common.safeWriteFlag only mkdirs the immediate parent; the skill lives two
    // levels under the workspace (skills/caveman/), so create the tree first
    // (mirrors writeFileSafe's fs.mkdirSync(dirname, {recursive:true})).
    if (!mkdirP(skill_dir)) return .{ .ok = false, .reason = "unsafe target" };

    const merged = try mergeOpenclawFrontmatter(gpa, skill_body);
    defer gpa.free(merged);
    common.safeWriteFlag(gpa, skill_file, merged) catch return .{ .ok = false, .reason = "unsafe target" };

    const soul = try appendBootstrapToSoul(gpa, soul_file, snippet);
    if (soul.skipped) return .{ .ok = false, .reason = "unsafe target" };

    return .{ .ok = true };
}

/// Uninstall: remove the skill folder and strip the SOUL.md block.
pub fn uninstallOpenclaw(gpa: std.mem.Allocator, workspace: []const u8, dry_run: bool) !void {
    const skill_dir = try std.fs.path.join(gpa, &.{ workspace, "skills", SKILL_NAME });
    defer gpa.free(skill_dir);
    const soul_file = try std.fs.path.join(gpa, &.{ workspace, SOUL_FILE });
    defer gpa.free(soul_file);

    if (common.classify(skill_dir) == .dir and !dry_run) {
        removeTree(gpa, skill_dir);
    }
    if (common.isRegularFileNoSymlink(soul_file) and !dry_run) {
        _ = stripBootstrapFromSoul(gpa, soul_file) catch {};
    }
}

// ── Filesystem helpers (libc) ───────────────────────────────────────────────
fn mkdirP(dir: []const u8) bool {
    if (common.ancestorUnsafe(dir)) return false;
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
    return common.classify(dir) == .dir;
}

/// Recursive directory removal (rmSync({recursive,force}) analogue). Best-effort.
/// libc opendir/readdir/closedir + per-entry lstat classification — stays on the
/// stable C ABI like the rest of the hook tree (std.fs.cwd() is gone in this
/// 0.16 build). Shared by openclaw + nullclaw uninstall.
pub fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    switch (common.classify(path)) {
        .missing, .symlink => return,
        .other => {
            var fbuf: [std.fs.max_path_bytes]u8 = undefined;
            if (common.toZ(&fbuf, path)) |fz| {
                _ = c.unlink(fz);
            } else |_| {}
            return;
        },
        .dir => {},
    }

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = common.toZ(&pbuf, path) catch return;

    const dp = c.opendir(pz) orelse {
        // Not a dir or unreadable — try a plain unlink.
        _ = c.unlink(pz);
        return;
    };
    {
        defer _ = c.closedir(dp);
        while (c.readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const child = std.fs.path.join(gpa, &.{ path, name }) catch continue;
            defer gpa.free(child);
            switch (common.classify(child)) {
                .dir => removeTree(gpa, child),
                else => {
                    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
                    if (common.toZ(&cbuf, child)) |cz| {
                        _ = c.unlink(cz);
                    } else |_| {}
                },
            }
        }
    }
    _ = c.rmdir(pz);
}

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "splitFrontmatter splits a simple block" {
    const src = "---\nname: caveman\ndescription: x\n---\nbody text\nmore\n";
    const sp = splitFrontmatter(src);
    try testing.expectEqualStrings("name: caveman\ndescription: x\n", sp.frontmatter);
    try testing.expectEqualStrings("body text\nmore\n", sp.body);
}

test "splitFrontmatter handles folded block scalar description" {
    const src = "---\nname: caveman\ndescription: >\n  multi line\n  desc here\n---\nbody\n";
    const sp = splitFrontmatter(src);
    try testing.expect(std.mem.indexOf(u8, sp.frontmatter, "description: >") != null);
    try testing.expect(std.mem.indexOf(u8, sp.frontmatter, "desc here") != null);
    try testing.expectEqualStrings("body\n", sp.body);
}

test "splitFrontmatter no fence yields empty frontmatter" {
    const src = "no frontmatter here\nbody\n";
    const sp = splitFrontmatter(src);
    try testing.expectEqualStrings("", sp.frontmatter);
    try testing.expectEqualStrings(src, sp.body);
}

test "frontmatterHasKey case-insensitive line-anchored" {
    const fm = "name: caveman\nVersion: 1.0.0\ndescription: x\n";
    try testing.expect(frontmatterHasKey(fm, "name"));
    try testing.expect(frontmatterHasKey(fm, "version")); // case-insensitive
    try testing.expect(frontmatterHasKey(fm, "always") == false);
    // must be line-anchored: "ame" inside "name" should not match key "ame"
    try testing.expect(frontmatterHasKey(fm, "ame") == false);
}

test "mergeOpenclawFrontmatter inserts name/version/always when absent" {
    const gpa = testing.allocator;
    const src = "---\ndescription: >\n  folded desc\n  line two\n---\nbody one\nbody two\n";
    const out = try mergeOpenclawFrontmatter(gpa, src);
    defer gpa.free(out);

    const sp = splitFrontmatter(out);
    try testing.expect(frontmatterHasKey(sp.frontmatter, "name"));
    try testing.expect(frontmatterHasKey(sp.frontmatter, "version"));
    try testing.expect(frontmatterHasKey(sp.frontmatter, "always"));
    // Original folded description preserved.
    try testing.expect(std.mem.indexOf(u8, sp.frontmatter, "description: >") != null);
    try testing.expect(std.mem.indexOf(u8, sp.frontmatter, "line two") != null);
    // Body byte-identical to source body.
    try testing.expectEqualStrings("body one\nbody two\n", sp.body);
    // exactly one always: key
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "always: true"));
}

test "mergeOpenclawFrontmatter is idempotent (no double-prepend)" {
    const gpa = testing.allocator;
    const src = "---\ndescription: x\n---\nbody\n";
    const once = try mergeOpenclawFrontmatter(gpa, src);
    defer gpa.free(once);
    const twice = try mergeOpenclawFrontmatter(gpa, once);
    defer gpa.free(twice);
    try testing.expectEqualStrings(once, twice); // second pass is a no-op copy

    const sp = splitFrontmatter(twice);
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "name: caveman"));
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "version: 1.0.0"));
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "always: true"));
}

test "mergeOpenclawFrontmatter only adds missing keys" {
    const gpa = testing.allocator;
    const src = "---\nname: caveman\nversion: 9.9.9\n---\nbody\n";
    const out = try mergeOpenclawFrontmatter(gpa, src);
    defer gpa.free(out);
    const sp = splitFrontmatter(out);
    // name + version preserved (not duplicated), always added.
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "name: caveman"));
    try testing.expectEqual(@as(usize, 1), countLines(sp.frontmatter, "version: 9.9.9"));
    try testing.expect(frontmatterHasKey(sp.frontmatter, "always"));
    // no caveman 1.0.0 version inserted
    try testing.expect(countLines(sp.frontmatter, "version: 1.0.0") == 0);
}

fn countLines(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, needle)) n += 1;
    }
    return n;
}

test "bootstrap snippet carries sentinel and both markers" {
    try testing.expect(std.mem.indexOf(u8, BOOTSTRAP_SNIPPET, SENTINEL) != null);
    try testing.expect(std.mem.indexOf(u8, BOOTSTRAP_SNIPPET, MARK_BEGIN) != null);
    try testing.expect(std.mem.indexOf(u8, BOOTSTRAP_SNIPPET, MARK_END) != null);
    try testing.expect(std.mem.endsWith(u8, BOOTSTRAP_SNIPPET, "\n"));
}

test "loadBootstrapSnippet normalizes trailing newline from repo body" {
    const gpa = testing.allocator;
    // repo body WITHOUT trailing newline → one appended.
    const body_no_nl = MARK_BEGIN ++ "\nx\n" ++ MARK_END;
    const out1 = try loadBootstrapSnippet(gpa, body_no_nl);
    defer gpa.free(out1);
    try testing.expect(std.mem.endsWith(u8, out1, MARK_END ++ "\n"));

    // repo body WITH trailing newline → unchanged length.
    const body_nl = MARK_BEGIN ++ "\nx\n" ++ MARK_END ++ "\n";
    const out2 = try loadBootstrapSnippet(gpa, body_nl);
    defer gpa.free(out2);
    try testing.expectEqualStrings(body_nl, out2);

    // null repo → inline fallback.
    const out3 = try loadBootstrapSnippet(gpa, null);
    defer gpa.free(out3);
    try testing.expectEqualStrings(BOOTSTRAP_SNIPPET, out3);
}

test "SOUL append/strip round-trip preserves user content" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const soul = try std.fs.path.join(gpa, &.{ dir_path, "SOUL.md" });
    defer gpa.free(soul);

    const user = "# my workspace\n\nfoo bar baz\n";
    try common.writeSmall(soul, user);

    // append
    const r1 = try appendBootstrapToSoul(gpa, soul, BOOTSTRAP_SNIPPET);
    try testing.expect(r1.changed);
    const after_append = common.readFileAlloc(gpa, soul, 1 << 20).?;
    defer gpa.free(after_append);
    try testing.expect(std.mem.indexOf(u8, after_append, "# my workspace") != null);
    try testing.expect(std.mem.indexOf(u8, after_append, MARK_BEGIN) != null);
    try testing.expect(std.mem.indexOf(u8, after_append, SENTINEL) != null);

    // idempotent append
    const r2 = try appendBootstrapToSoul(gpa, soul, BOOTSTRAP_SNIPPET);
    try testing.expect(!r2.changed);
    const after_append2 = common.readFileAlloc(gpa, soul, 1 << 20).?;
    defer gpa.free(after_append2);
    try testing.expectEqual(@as(usize, 1), countOccurrences(after_append2, MARK_BEGIN));

    // strip — user content restored, block gone
    const r3 = try stripBootstrapFromSoul(gpa, soul);
    try testing.expect(r3.changed);
    try testing.expect(!r3.removed);
    const after_strip = common.readFileAlloc(gpa, soul, 1 << 20).?;
    defer gpa.free(after_strip);
    try testing.expect(std.mem.indexOf(u8, after_strip, "# my workspace") != null);
    try testing.expect(std.mem.indexOf(u8, after_strip, "foo bar baz") != null);
    try testing.expect(std.mem.indexOf(u8, after_strip, MARK_BEGIN) == null);

    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&fb, soul));
}

test "SOUL strip removes file when only our block present" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const soul = try std.fs.path.join(gpa, &.{ dir_path, "SOUL.md" });
    defer gpa.free(soul);

    // create SOUL.md with only the bootstrap block
    const r0 = try appendBootstrapToSoul(gpa, soul, BOOTSTRAP_SNIPPET);
    try testing.expect(r0.changed);

    const r1 = try stripBootstrapFromSoul(gpa, soul);
    try testing.expect(r1.changed);
    try testing.expect(r1.removed);
    try testing.expect(common.classify(soul) == .missing);
}

test "appendBootstrapToSoul refuses symlinked target" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim.md" });
    defer gpa.free(victim);
    const soul = try std.fs.path.join(gpa, &.{ dir_path, "SOUL.md" });
    defer gpa.free(soul);

    try common.writeSmall(victim, "VICTIM\n");
    var vb: [std.fs.max_path_bytes]u8 = undefined;
    var sb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(c.symlink(try common.toZ(&vb, victim), try common.toZ(&sb, soul)) == 0);

    const r = try appendBootstrapToSoul(gpa, soul, BOOTSTRAP_SNIPPET);
    try testing.expect(!r.changed);
    try testing.expect(r.skipped);
    const data = try common.readSmall(gpa, victim);
    defer gpa.free(data);
    try testing.expectEqualStrings("VICTIM\n", data);

    _ = c.unlink(try common.toZ(&sb, soul));
    _ = c.unlink(try common.toZ(&vb, victim));
}

test "appendBootstrapToSoul skips unreadable oversized existing SOUL" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const soul = try std.fs.path.join(gpa, &.{ dir_path, "SOUL.md" });
    defer gpa.free(soul);

    const big = try gpa.alloc(u8, 4 * 1024 * 1024 + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    try common.safeWriteFlag(gpa, soul, big);

    const r = try appendBootstrapToSoul(gpa, soul, BOOTSTRAP_SNIPPET);
    try testing.expect(!r.changed);
    try testing.expect(r.skipped);

    const first = try common.readSmall(gpa, soul);
    defer gpa.free(first);
    try testing.expect(first.len > 0);
    try testing.expect(first[0] == 'x');

    var sb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&sb, soul));
}

test "removeTree refuses symlinked root directory" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim" });
    defer gpa.free(victim);
    try common.mkdirPath(victim);
    const marker = try std.fs.path.join(gpa, &.{ victim, "marker.txt" });
    defer gpa.free(marker);
    try common.writeSmall(marker, "keep\n");

    const link = try std.fs.path.join(gpa, &.{ dir_path, "link" });
    defer gpa.free(link);
    var vb: [std.fs.max_path_bytes]u8 = undefined;
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(c.symlink(try common.toZ(&vb, victim), try common.toZ(&lb, link)) == 0);

    removeTree(gpa, link);
    try testing.expect(common.classify(link) == .symlink);
    const data = try common.readSmall(gpa, marker);
    defer gpa.free(data);
    try testing.expectEqualStrings("keep\n", data);

    _ = c.unlink(try common.toZ(&lb, link));
    var mb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try common.toZ(&mb, marker));
    _ = c.rmdir(try common.toZ(&vb, victim));
}

test "resolveWorkspace honors OPENCLAW_WORKSPACE" {
    const gpa = testing.allocator;
    const old = try common.saveEnv(gpa, "OPENCLAW_WORKSPACE");
    defer if (old) |v| gpa.free(v);
    defer common.restoreEnv("OPENCLAW_WORKSPACE", old);

    _ = common.setenv("OPENCLAW_WORKSPACE", "/tmp/oc-ws-test", 1);
    const ws = try resolveWorkspace(gpa);
    defer gpa.free(ws);
    try testing.expectEqualStrings("/tmp/oc-ws-test", ws);
}

test "installOpenclaw writes skill + SOUL, idempotent" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "ws" });
    defer gpa.free(ws);
    try common.mkdirPath(ws);

    const skill_body = "---\ndescription: x\n---\nRespond terse like smart caveman.\n";

    const r1 = try installOpenclaw(gpa, ws, skill_body, BOOTSTRAP_SNIPPET, false, false);
    try testing.expect(r1.ok);

    const skill_file = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman", "SKILL.md" });
    defer gpa.free(skill_file);
    const skill_raw = common.readFileAlloc(gpa, skill_file, 1 << 20).?;
    defer gpa.free(skill_raw);
    try testing.expect(std.mem.indexOf(u8, skill_raw, "always: true") != null);
    try testing.expect(std.mem.indexOf(u8, skill_raw, "version: 1.0.0") != null);

    const soul_file = try std.fs.path.join(gpa, &.{ ws, "SOUL.md" });
    defer gpa.free(soul_file);
    const soul_raw = common.readFileAlloc(gpa, soul_file, 1 << 20).?;
    defer gpa.free(soul_raw);
    try testing.expect(std.mem.indexOf(u8, soul_raw, SENTINEL) != null);

    // idempotent re-run: still one always: key, one marker block.
    const r2 = try installOpenclaw(gpa, ws, skill_body, BOOTSTRAP_SNIPPET, false, false);
    try testing.expect(r2.ok);
    const skill_raw2 = common.readFileAlloc(gpa, skill_file, 1 << 20).?;
    defer gpa.free(skill_raw2);
    try testing.expectEqual(@as(usize, 1), countOccurrences(skill_raw2, "always: true"));
    const soul_raw2 = common.readFileAlloc(gpa, soul_file, 1 << 20).?;
    defer gpa.free(soul_raw2);
    try testing.expectEqual(@as(usize, 1), countOccurrences(soul_raw2, MARK_BEGIN));

    // uninstall clears it
    try uninstallOpenclaw(gpa, ws, false);
    const skill_dir = try std.fs.path.join(gpa, &.{ ws, "skills", "caveman" });
    defer gpa.free(skill_dir);
    try testing.expect(common.classify(skill_dir) == .missing);
}

test "installOpenclaw reports workspace missing without force" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const ws = try std.fs.path.join(gpa, &.{ dir_path, "missing-ws" });
    defer gpa.free(ws);

    const skill_body = "---\ndescription: x\n---\nbody\n";
    const r = try installOpenclaw(gpa, ws, skill_body, BOOTSTRAP_SNIPPET, false, false);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("workspace missing", r.reason);
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
