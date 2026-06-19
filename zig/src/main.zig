//! Caveman/Ponytail UserPromptSubmit hook — Zig 0.16 PoC.
//!
//! Replaces the Node hook. Reads the hook JSON event on stdin, detects a
//! `/<tool> <level>` slash command, persists the mode through a SYMLINK-SAFE
//! flag write, and emits the hookSpecificOutput JSON the harness injects back
//! as per-turn reinforcement.
//!
//! Written against the stable libc C ABI (std.c + a couple of extern decls)
//! rather than the in-flight std.Io surface: a hook binary links libc anyway
//! and this keeps the PoC pinned to a stable interface. Production rewrite can
//! migrate to std.Io once 0.16 stabilizes; the security logic is identical.
//!
//! Security property (the one ponytail's JS lacks): the flag write refuses to
//! follow a symlink at the target path or its parent, writes to a temp file
//! opened O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW with mode 0600, then atomically
//! renames. A local attacker who pre-plants a symlink at the predictable flag
//! path cannot redirect the write onto e.g. ~/.ssh/authorized_keys.

const std = @import("std");
const build_options = @import("build_options");
const c = std.c;

const TOOL = build_options.tool; // "caveman" or "ponytail"

// libc decls not surfaced under these names in std.c for this dev build.
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *c.Stat) c_int;
// resolved_path must point to a buffer of at least PATH_MAX bytes.
extern "c" fn realpath(path: [*:0]const u8, resolved_path: [*]u8) ?[*:0]u8;

const VALID_MODES = [_][]const u8{ "lite", "full", "ultra", "wenyan-lite", "wenyan-full", "wenyan-ultra" };

const FlagError = error{
    SymlinkRefused,
    ParentSymlinkRefused,
    OpenFailed,
    WriteFailed,
    RenameFailed,
    PathTooLong,
    NoHome,
} || std.mem.Allocator.Error;

fn isValidMode(mode: []const u8) bool {
    for (VALID_MODES) |m| {
        if (std.mem.eql(u8, m, mode)) return true;
    }
    return false;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

/// Resolve flag path: $CLAUDE_CONFIG_DIR (or $HOME/.claude) + ".<tool>-active".
fn flagPath(gpa: std.mem.Allocator) FlagError![]u8 {
    if (getenv("CLAUDE_CONFIG_DIR")) |base| {
        return std.fs.path.join(gpa, &.{ base, "." ++ TOOL ++ "-active" });
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude", "." ++ TOOL ++ "-active" });
}

/// Copy a slice into a fixed NUL-terminated buffer for C calls.
fn toZ(buf: []u8, s: []const u8) FlagError![*:0]const u8 {
    if (s.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// lstat a path; true if it exists AND is a symlink (refuse-on-symlink check).
fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return true; // refuse pathological lengths
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return false; // ENOENT etc → not a symlink
    return (st.mode & c.S.IFMT) == c.S.IFLNK;
}

/// lstat; classify a path component as a (real) directory, a symlink, missing,
/// or other. Used to walk a directory chain refusing any non-directory link.
const Comp = enum { dir, symlink, missing, other };
fn classify(path: []const u8) Comp {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return .symlink; // pathological → treat unsafe
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return .missing;
    const kind = st.mode & c.S.IFMT;
    if (kind == c.S.IFLNK) return .symlink;
    if (kind == c.S.IFDIR) return .dir;
    return .other;
}

/// realpath a path into `out` (libc realpath(3)); returns the resolved slice or
/// null on failure. `out` must be >= PATH_MAX.
fn realpathZ(path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var ibuf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&ibuf, path) catch return null;
    const r = realpath(z, out) orelse return null;
    return std.mem.sliceTo(r, 0);
}

/// True if reaching `dir` would pass through a symlink an attacker could plant
/// at ANY level below a trusted base — not just the immediate parent. Mirrors
/// the JS hooks fs-safe isAnyAncestorSymlink: anchor on the realpath of the
/// longest trusted base that lexically prefixes `dir` (absorbing benign system
/// links like /var above the user area), then lstat-walk each tail component,
/// refusing any symlinked or non-directory ancestor.
fn ancestorUnsafe(dir: []const u8) bool {
    const bases: [3]?[]const u8 = .{ getenv("HOME"), getenv("TMPDIR"), getenv("CLAUDE_CONFIG_DIR") };

    var best_base: ?[]const u8 = null;
    for (bases) |maybe| {
        const b = maybe orelse continue;
        if (std.mem.eql(u8, dir, b) or
            (dir.len > b.len and std.mem.startsWith(u8, dir, b) and dir[b.len] == '/'))
        {
            if (best_base == null or b.len > best_base.?.len) best_base = b;
        }
    }
    const base = best_base orelse return true; // outside every trusted base → refuse

    var anchor_buf: [std.fs.max_path_bytes]u8 = undefined;
    const anchor = realpathZ(base, &anchor_buf) orelse return true;

    const tail = dir[base.len..]; // leading '/' or empty
    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (anchor.len >= cur_buf.len) return true;
    @memcpy(cur_buf[0..anchor.len], anchor);
    var cur_len = anchor.len;

    var it = std.mem.tokenizeScalar(u8, tail, '/');
    while (it.next()) |part| {
        if (cur_len + 1 + part.len >= cur_buf.len) return true;
        cur_buf[cur_len] = '/';
        @memcpy(cur_buf[cur_len + 1 ..][0..part.len], part);
        cur_len += 1 + part.len;
        const cur = cur_buf[0..cur_len];
        switch (classify(cur)) {
            .missing => return false, // tail not created yet → mkdir makes real dirs
            .symlink, .other => return true,
            .dir => {},
        }
    }
    return false;
}

/// Symlink-safe atomic flag write. The security core.
fn safeWriteFlag(gpa: std.mem.Allocator, path: []const u8, content: []const u8) FlagError!void {
    if (isSymlink(path)) return error.SymlinkRefused;

    const dir = std.fs.path.dirname(path) orelse ".";
    // Refuse if ANY ancestor directory (not just the immediate parent) is a
    // symlink an attacker could have planted to redirect the open/rename.
    if (ancestorUnsafe(dir)) return error.ParentSymlinkRefused;

    // Ensure parent exists (0700). Ignore errors (already-exists / race).
    {
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (toZ(&dbuf, dir)) |dz| {
            _ = c.mkdir(dz, 0o700);
        } else |_| {}
    }

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ path, c.getpid() });
    defer gpa.free(tmp);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tz = try toZ(&tbuf, tmp);

    // O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600.
    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = c.open(tz, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    {
        defer _ = close(fd);
        var written: usize = 0;
        while (written < content.len) {
            const n = c.write(fd, content.ptr + written, content.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    if (c.rename(tz, pz) != 0) {
        _ = c.unlink(tz);
        return error.RenameFailed;
    }
}

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

/// Parse `/<tool> <level>` → mode, or null. Mirrors the JS mode-tracker.
fn parseSlashMode(prompt: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const cmd = "/" ++ TOOL;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return null;
    // Exact first-token match — startsWith would accept "/<tool>x ..." and
    // wrongly activate mode parsing.
    if (!std.mem.eql(u8, first, cmd)) return null;
    const arg = it.next() orelse return "full"; // bare → default
    if (std.mem.eql(u8, arg, "wenyan")) return "wenyan-full"; // alias
    if (isValidMode(arg)) return arg;
    return null;
}

/// Read all of stdin into an owned buffer using raw read(2).
fn readStdin(gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input = readStdin(gpa) catch return; // silent-fail contract
    defer gpa.free(input);

    const prompt = extractPrompt(gpa, input) orelse return;
    defer gpa.free(prompt);

    const mode = parseSlashMode(prompt) orelse return;

    // Silent-fail if env is missing/invalid (e.g. no HOME) — a hook must never
    // bubble an error out of main and disturb prompt submission.
    const path = flagPath(gpa) catch return;
    defer gpa.free(path);
    safeWriteFlag(gpa, path, mode) catch return; // silent-fail on FS errors

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

test "isValidMode whitelist rejects injection" {
    try std.testing.expect(isValidMode("full"));
    try std.testing.expect(isValidMode("wenyan-ultra"));
    try std.testing.expect(!isValidMode("rm -rf /"));
    try std.testing.expect(!isValidMode("../../etc/passwd"));
    try std.testing.expect(!isValidMode(""));
}

test "parseSlashMode" {
    try std.testing.expectEqualStrings("full", parseSlashMode("/" ++ TOOL).?);
    try std.testing.expectEqualStrings("ultra", parseSlashMode("/" ++ TOOL ++ " ultra").?);
    try std.testing.expectEqualStrings("wenyan-full", parseSlashMode("/" ++ TOOL ++ " wenyan").?);
    try std.testing.expect(parseSlashMode("hello world") == null);
    try std.testing.expect(parseSlashMode("/" ++ TOOL ++ " bogus") == null);
    try std.testing.expect(parseSlashMode("/" ++ TOOL ++ "x ultra") == null); // prefix, not exact
}

test "extractPrompt pulls prompt field" {
    const gpa = std.testing.allocator;
    const got = extractPrompt(gpa, "{\"prompt\":\"/" ++ TOOL ++ " ultra\",\"x\":1}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/" ++ TOOL ++ " ultra", got);
    try std.testing.expect(extractPrompt(gpa, "not json") == null);
}

/// Make a unique temp dir via libc (Io-free; matches the code under test).
fn makeTmpDir(gpa: std.mem.Allocator) ![]u8 {
    const base = getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/zighooktest.{d}", .{ base, c.getpid() });
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try toZ(&dbuf, dir);
    _ = c.mkdir(dz, 0o700);
    return dir;
}

fn readSmall(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    const flags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var buf: [256]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    return gpa.dupe(u8, buf[0..@intCast(n)]);
}

test "safeWriteFlag refuses symlinked target (clobber attack)" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim.txt" });
    defer gpa.free(victim);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active" });
    defer gpa.free(flag);

    // Create victim with SECRET via the code's own write helpers.
    {
        var vb: [std.fs.max_path_bytes]u8 = undefined;
        const vz = try toZ(&vb, victim);
        const fl: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };
        const fd = c.open(vz, fl, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        _ = c.write(fd, "SECRET", 6);
        _ = close(fd);
    }

    var vbuf: [std.fs.max_path_bytes]u8 = undefined;
    var fbuf: [std.fs.max_path_bytes]u8 = undefined;
    const vz = try toZ(&vbuf, victim);
    const fz = try toZ(&fbuf, flag);
    try std.testing.expect(c.symlink(vz, fz) == 0); // plant flag -> victim

    try std.testing.expectError(error.SymlinkRefused, safeWriteFlag(gpa, flag, "full"));

    const data = try readSmall(gpa, victim);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("SECRET", data); // untouched

    _ = c.unlink(fz);
    _ = c.unlink(vz);
}

test "safeWriteFlag writes mode on clean path" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active2" });
    defer gpa.free(flag);

    try safeWriteFlag(gpa, flag, "ultra");
    const data = try readSmall(gpa, flag);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("ultra", data);

    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try toZ(&fb, flag));
}

test "safeWriteFlag refuses symlinked GRANDPARENT (ancestor) dir" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);

    // real/inner is the genuine tree; link -> real is the symlinked grandparent.
    const real = try std.fs.path.join(gpa, &.{ dir_path, "real" });
    defer gpa.free(real);
    const inner = try std.fs.path.join(gpa, &.{ real, "inner" });
    defer gpa.free(inner);
    const link = try std.fs.path.join(gpa, &.{ dir_path, "link" });
    defer gpa.free(link);

    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    var b3: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.mkdir(try toZ(&b1, real), 0o700);
    _ = c.mkdir(try toZ(&b2, inner), 0o700);
    try std.testing.expect(c.symlink(try toZ(&b1, real), try toZ(&b3, link)) == 0);

    const flag = try std.fs.path.join(gpa, &.{ link, "inner", ".active3" });
    defer gpa.free(flag);

    try std.testing.expectError(error.ParentSymlinkRefused, safeWriteFlag(gpa, flag, "full"));

    const real_flag = try std.fs.path.join(gpa, &.{ inner, ".active3" });
    defer gpa.free(real_flag);
    try std.testing.expect(classify(real_flag) == .missing);

    _ = c.unlink(try toZ(&b3, link));
}
