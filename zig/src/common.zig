//! Shared caveman/ponytail hook primitives — Zig 0.16, libc C-ABI.
//!
//! Extracted from the original single-file PoC so the UserPromptSubmit hook
//! (main.zig), the SessionStart activate binary (activate.zig), and the
//! statusline (statusline.zig) all share one copy of:
//!
//!   - TOOL identity (comptime, from -Dtool)
//!   - the mode whitelist + canonicalMode / isValidMode / isIndependentMode
//!   - getDefaultMode + the env/repo/user config resolution chain
//!   - the symlink-safe flag write (safeWriteFlag + ancestorUnsafe) — the
//!     security core: refuse-on-symlink, atomic temp+rename, O_NOFOLLOW, 0600
//!   - flagPath resolution
//!   - the libc read/write/path helpers everything needs
//!
//! Written against the stable libc C ABI (std.c + a few extern decls) rather
//! than the in-flight std.Io surface — every hook binary links libc anyway and
//! this keeps the security logic pinned to a stable interface. The PoC can
//! migrate to std.Io once 0.16 stabilizes; the security properties are identical.

const std = @import("std");
const build_options = @import("build_options");
const c = std.c;

/// "caveman" or "ponytail" — selected at configure time by -Dtool.
pub const TOOL = build_options.tool;

/// Per-tool flag filename: ".<tool>-active".
pub const FLAG_NAME = "." ++ TOOL ++ "-active";

/// Pre-rendered savings-suffix filename written by caveman-stats.js.
pub const STATUSLINE_SUFFIX_NAME = "." ++ TOOL ++ "-statusline-suffix";

// libc decls not surfaced under these names in std.c for this dev build.
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn lstat(path: [*:0]const u8, buf: *c.Stat) c_int;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;
// resolved_path must point to a buffer of at least PATH_MAX bytes.
pub extern "c" fn realpath(path: [*:0]const u8, resolved_path: [*]u8) ?[*:0]u8;

pub const VALID_MODES = [_][]const u8{
    "off",
    "lite",
    "full",
    "ultra",
    "wenyan-lite",
    "wenyan",
    "wenyan-full",
    "wenyan-ultra",
    "commit",
    "review",
    "compress",
};

pub const FlagError = error{
    SymlinkRefused,
    ParentSymlinkRefused,
    OpenFailed,
    WriteFailed,
    ReadFailed,
    RenameFailed,
    PathTooLong,
    NoHome,
} || std.mem.Allocator.Error;

pub fn canonicalMode(mode: []const u8) ?[]const u8 {
    for (VALID_MODES) |m| {
        if (std.ascii.eqlIgnoreCase(m, mode)) return m;
    }
    return null;
}

pub fn isValidMode(mode: []const u8) bool {
    return canonicalMode(mode) != null;
}

pub fn isIndependentMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "commit") or
        std.mem.eql(u8, mode, "review") or
        std.mem.eql(u8, mode, "compress");
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

/// Resolve flag path: $CLAUDE_CONFIG_DIR (or $HOME/.claude) + ".<tool>-active".
pub fn flagPath(gpa: std.mem.Allocator) FlagError![]u8 {
    if (getenv("CLAUDE_CONFIG_DIR")) |base| {
        return std.fs.path.join(gpa, &.{ base, FLAG_NAME });
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude", FLAG_NAME });
}

/// Resolve an arbitrary file under the Claude config dir.
/// $CLAUDE_CONFIG_DIR (or $HOME/.claude) joined with `name`.
pub fn claudeConfigFile(gpa: std.mem.Allocator, name: []const u8) FlagError![]u8 {
    if (getenv("CLAUDE_CONFIG_DIR")) |base| {
        return std.fs.path.join(gpa, &.{ base, name });
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude", name });
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return null;
    const flags: c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = close(fd);

    var out: std.ArrayList(u8) = .empty;
    var buf: [512]u8 = undefined;
    while (out.items.len <= max_bytes) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            out.deinit(gpa);
            return null;
        }
        if (n == 0) {
            return out.toOwnedSlice(gpa) catch {
                out.deinit(gpa);
                return null;
            };
        }
        const next_len = out.items.len + @as(usize, @intCast(n));
        if (next_len > max_bytes) {
            out.deinit(gpa);
            return null;
        }
        out.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    out.deinit(gpa);
    return null;
}

pub fn isRegularFileNoSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return false;
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return false;
    return (st.mode & c.S.IFMT) == c.S.IFREG;
}

pub fn existsNoFollow(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return false;
    var st: c.Stat = undefined;
    return lstat(z, &st) == 0;
}

fn readModeFromConfigFile(gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (!isRegularFileNoSymlink(path)) return null;
    const raw = readFileAlloc(gpa, path, 16 * 1024) orelse return null;
    defer gpa.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const value = obj.get("defaultMode") orelse return null;
    const mode = switch (value) {
        .string => |s| s,
        else => return null,
    };
    return canonicalMode(mode);
}

fn repoConfigMode(gpa: std.mem.Allocator) ?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return null;
    var dir: []const u8 = std.mem.sliceTo(cwd_z, 0);

    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const nested = std.fs.path.join(gpa, &.{ dir, ".caveman", "config.json" }) catch return null;
        defer gpa.free(nested);
        if (readModeFromConfigFile(gpa, nested)) |mode| return mode;

        const flat = std.fs.path.join(gpa, &.{ dir, ".caveman.json" }) catch return null;
        defer gpa.free(flat);
        if (readModeFromConfigFile(gpa, flat)) |mode| return mode;

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
    return null;
}

fn userConfigMode(gpa: std.mem.Allocator) ?[]const u8 {
    const path = if (getenv("XDG_CONFIG_HOME")) |xdg|
        std.fs.path.join(gpa, &.{ xdg, "caveman", "config.json" }) catch return null
    else if (getenv("HOME")) |home|
        std.fs.path.join(gpa, &.{ home, ".config", "caveman", "config.json" }) catch return null
    else if (getenv("APPDATA")) |appdata|
        std.fs.path.join(gpa, &.{ appdata, "caveman", "config.json" }) catch return null
    else
        return null;
    defer gpa.free(path);
    return readModeFromConfigFile(gpa, path);
}

pub fn getDefaultMode(gpa: std.mem.Allocator) []const u8 {
    if (getenv("CAVEMAN_DEFAULT_MODE")) |mode| {
        if (canonicalMode(mode)) |m| return m;
    }
    if (repoConfigMode(gpa)) |mode| return mode;
    if (userConfigMode(gpa)) |mode| return mode;
    return "full";
}

/// Copy a slice into a fixed NUL-terminated buffer for C calls.
pub fn toZ(buf: []u8, s: []const u8) FlagError![*:0]const u8 {
    if (s.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// lstat a path; true if it exists AND is a symlink (refuse-on-symlink check).
pub fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return true; // refuse pathological lengths
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return false; // ENOENT etc → not a symlink
    return (st.mode & c.S.IFMT) == c.S.IFLNK;
}

/// lstat; classify a path component as a (real) directory, a symlink, missing,
/// or other. Used to walk a directory chain refusing any non-directory link.
pub const Comp = enum { dir, symlink, missing, other };
pub fn classify(path: []const u8) Comp {
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
/// Strip trailing '/' chars (but keep a lone "/"). Mirrors how path.resolve
/// normalizes a base before a prefix comparison.
fn trimTrailingSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

const Anchor = struct {
    prefix: []const u8,
    resolved: []const u8,
};

fn existingAnchorForBase(base: []const u8, out: *[std.fs.max_path_bytes]u8) ?Anchor {
    var prefix = base;
    while (prefix.len > 0) {
        if (realpathZ(prefix, out)) |resolved| {
            return .{ .prefix = prefix, .resolved = resolved };
        }
        const parent = std.fs.path.dirname(prefix) orelse return null;
        if (parent.len == prefix.len) return null;
        prefix = parent;
    }
    return null;
}

pub fn ancestorUnsafe(dir: []const u8) bool {
    const bases: [7]?[]const u8 = .{
        getenv("HOME"),
        getenv("TMPDIR"),
        getenv("CLAUDE_CONFIG_DIR"),
        getenv("XDG_CONFIG_HOME"),
        getenv("OPENCODE_CONFIG_DIR"),
        getenv("OPENCLAW_WORKSPACE"),
        getenv("NULLCLAW_WORKSPACE"),
    };

    var best_base: ?[]const u8 = null;
    for (bases) |maybe| {
        const raw = maybe orelse continue;
        // Normalize a trailing slash off the base before the prefix check. A base
        // like `$TMPDIR` is commonly `/var/.../T/` (trailing slash); without
        // trimming, `dir[b.len]` lands one char too far and never equals '/', so
        // a legitimately-under-base dir would be refused. JS normalizes via
        // path.resolve; we strip the trailing '/' to match.
        const b = trimTrailingSlash(raw);
        if (b.len == 0) continue;
        if (std.mem.eql(u8, dir, b) or
            (dir.len > b.len and std.mem.startsWith(u8, dir, b) and dir[b.len] == '/'))
        {
            if (best_base == null or b.len > best_base.?.len) best_base = b;
        }
    }
    const base = best_base orelse return true; // outside every trusted base → refuse

    var anchor_buf: [std.fs.max_path_bytes]u8 = undefined;
    const anchor_info = existingAnchorForBase(base, &anchor_buf) orelse return true;
    const anchor = anchor_info.resolved;

    const tail = dir[anchor_info.prefix.len..]; // leading '/' or empty
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
pub fn safeWriteFlag(gpa: std.mem.Allocator, path: []const u8, content: []const u8) FlagError!void {
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

/// Symlink-safe, size-capped, whitelist-validated flag read.
/// Mirrors caveman-config.js readFlag: refuses symlinks, caps at 64 bytes,
/// lowercases + trims, returns the canonical mode or null on any anomaly.
pub const MAX_FLAG_BYTES = 64;
pub fn readFlagMode(gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (!isRegularFileNoSymlink(path)) return null;
    const raw = readFileAlloc(gpa, path, MAX_FLAG_BYTES) orelse return null;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return canonicalMode(trimmed);
}

/// Read all of stdin into an owned buffer using raw read(2).
pub fn readStdin(gpa: std.mem.Allocator) ![]u8 {
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

pub fn writeStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

/// Current wall-clock time in milliseconds since the Unix epoch via libc
/// gettimeofday(2) — the C-ABI equivalent of JS Date.now(). std.time has moved
/// to the Io surface in this 0.16 build, so we route through libc to stay on
/// the stable C ABI like the rest of these hooks. Returns 0 on failure.
pub fn nowMillis() i64 {
    var tv: c.timeval = undefined;
    if (c.gettimeofday(&tv, null) != 0) return 0;
    const sec: i64 = @intCast(tv.sec);
    const usec: i64 = @intCast(tv.usec);
    return sec * 1000 + @divTrunc(usec, 1000);
}

pub fn writeStderr(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(2, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

pub fn unlinkFlag(path: []const u8) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return;
    _ = c.unlink(pz);
}

/// Pre-rendered savings-suffix path under the Claude config dir.
pub fn statuslineSuffixPath(gpa: std.mem.Allocator) FlagError![]u8 {
    return claudeConfigFile(gpa, STATUSLINE_SUFFIX_NAME);
}

/// Lifetime stats log filename ($CLAUDE_CONFIG_DIR/.<tool>-history.jsonl).
pub const HISTORY_NAME = "." ++ TOOL ++ "-history.jsonl";

/// Resolve the lifetime history JSONL path.
pub fn historyPath(gpa: std.mem.Allocator) FlagError![]u8 {
    return claudeConfigFile(gpa, HISTORY_NAME);
}

/// Symlink-safe append to the history JSONL. Mirrors caveman-config.js
/// appendFlag: O_APPEND|O_CREAT|O_NOFOLLOW, mode 0600, refuse-on-symlink for
/// both the target file and any ancestor of its parent, ensure parent exists,
/// and normalize the trailing newline (strip then add exactly one). Best-effort:
/// silent-fails on every filesystem error — history is never load-bearing.
pub fn appendHistory(path: []const u8, line: []const u8) void {
    if (isSymlink(path)) return;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (ancestorUnsafe(dir)) return;

    {
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (toZ(&dbuf, dir)) |dz| {
            _ = c.mkdir(dz, 0o700);
        } else |_| {}
    }

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return;

    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true };
    const fd = c.open(pz, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = close(fd);

    // Mirror JS: String(line).replace(/\n$/, '') + '\n' — strip a single
    // trailing newline, then write the line plus exactly one newline.
    const body = if (line.len > 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
    var written: usize = 0;
    while (written < body.len) {
        const n = c.write(fd, body.ptr + written, body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    const nl = "\n";
    _ = c.write(fd, nl.ptr, 1);
}

/// Symlink-safe history read. Returns the whole file as an owned buffer or null.
/// Mirrors caveman-config.js readHistory: refuse symlinks / non-regular files,
/// no size cap (history grows with use). Caller splits + parses lines.
pub fn readHistoryFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (isSymlink(path)) return null;
    if (!isRegularFileNoSymlink(path)) return null;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return null;
    const flags: c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = close(fd);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            out.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "isValidMode whitelist rejects injection" {
    try std.testing.expect(isValidMode("off"));
    try std.testing.expect(isValidMode("full"));
    try std.testing.expect(isValidMode("wenyan"));
    try std.testing.expect(isValidMode("wenyan-ultra"));
    try std.testing.expect(isValidMode("commit"));
    try std.testing.expect(isValidMode("review"));
    try std.testing.expect(isValidMode("compress"));
    try std.testing.expect(isValidMode("FULL"));
    try std.testing.expect(!isValidMode("rm -rf /"));
    try std.testing.expect(!isValidMode("../../etc/passwd"));
    try std.testing.expect(!isValidMode(""));
}

/// Make a unique temp dir via libc (Io-free; matches the code under test).
pub fn makeTmpDir(gpa: std.mem.Allocator) ![]u8 {
    const base = getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/zighooktest.{d}", .{ base, c.getpid() });
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try toZ(&dbuf, dir);
    _ = c.mkdir(dz, 0o700);
    return dir;
}

pub fn readSmall(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
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

pub fn writeSmall(path: []const u8, content: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    _ = c.unlink(pz);
    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };
    const fd = c.open(pz, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = c.write(fd, content.ptr + written, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn mkdirPath(path: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    _ = c.mkdir(pz, 0o700);
}

pub fn saveEnv(gpa: std.mem.Allocator, name: [*:0]const u8) !?[:0]u8 {
    const value = getenv(name) orelse return null;
    return try gpa.dupeZ(u8, value);
}

pub fn restoreEnv(name: [*:0]const u8, value: ?[:0]u8) void {
    if (value) |v| {
        _ = setenv(name, v.ptr, 1);
    } else {
        _ = unsetenv(name);
    }
}

test "getDefaultMode reads env before config" {
    const gpa = std.testing.allocator;
    const old_default = try saveEnv(gpa, "CAVEMAN_DEFAULT_MODE");
    defer if (old_default) |v| gpa.free(v);
    defer restoreEnv("CAVEMAN_DEFAULT_MODE", old_default);

    _ = setenv("CAVEMAN_DEFAULT_MODE", "ULTRA", 1);
    try std.testing.expectEqualStrings("ultra", getDefaultMode(gpa));

    _ = setenv("CAVEMAN_DEFAULT_MODE", "not-a-mode", 1);
    try std.testing.expect(!std.mem.eql(u8, getDefaultMode(gpa), "not-a-mode"));
}

test "getDefaultMode reads XDG user config" {
    const gpa = std.testing.allocator;
    const old_default = try saveEnv(gpa, "CAVEMAN_DEFAULT_MODE");
    defer if (old_default) |v| gpa.free(v);
    defer restoreEnv("CAVEMAN_DEFAULT_MODE", old_default);
    const old_xdg = try saveEnv(gpa, "XDG_CONFIG_HOME");
    defer if (old_xdg) |v| gpa.free(v);
    defer restoreEnv("XDG_CONFIG_HOME", old_xdg);

    _ = unsetenv("CAVEMAN_DEFAULT_MODE");

    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const xdg = try std.fs.path.join(gpa, &.{ dir_path, "xdg" });
    defer gpa.free(xdg);
    const caveman_dir = try std.fs.path.join(gpa, &.{ xdg, "caveman" });
    defer gpa.free(caveman_dir);
    const config = try std.fs.path.join(gpa, &.{ caveman_dir, "config.json" });
    defer gpa.free(config);

    try mkdirPath(xdg);
    try mkdirPath(caveman_dir);
    try writeSmall(config, "{\"defaultMode\":\"review\"}");

    const xdg_z = try gpa.dupeZ(u8, xdg);
    defer gpa.free(xdg_z);
    _ = setenv("XDG_CONFIG_HOME", xdg_z.ptr, 1);

    try std.testing.expectEqualStrings("review", getDefaultMode(gpa));
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

test "safeWriteFlag honors configured opencode root outside HOME" {
    const gpa = std.testing.allocator;
    const old_tmp = try saveEnv(gpa, "TMPDIR");
    defer if (old_tmp) |v| gpa.free(v);
    defer restoreEnv("TMPDIR", old_tmp);
    const old_opencode = try saveEnv(gpa, "OPENCODE_CONFIG_DIR");
    defer if (old_opencode) |v| gpa.free(v);
    defer restoreEnv("OPENCODE_CONFIG_DIR", old_opencode);

    _ = unsetenv("TMPDIR");

    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const root = try std.fs.path.join(gpa, &.{ dir_path, "external-opencode" });
    defer gpa.free(root);
    try mkdirPath(root);

    const root_z = try gpa.dupeZ(u8, root);
    defer gpa.free(root_z);
    _ = setenv("OPENCODE_CONFIG_DIR", root_z.ptr, 1);

    const nested = try std.fs.path.join(gpa, &.{ root, "plugins", "caveman" });
    defer gpa.free(nested);
    try std.testing.expect(!ancestorUnsafe(nested));

    const settings = try std.fs.path.join(gpa, &.{ root, "opencode.json" });
    defer gpa.free(settings);
    try safeWriteFlag(gpa, settings, "{}\n");
    const data = try readSmall(gpa, settings);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{}\n", data);

    var sbuf: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try toZ(&sbuf, settings));
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

test "readFlagMode whitelist + symlink refusal" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".readflag" });
    defer gpa.free(flag);

    // Valid mode, with trailing newline + uppercase → canonicalized.
    try writeSmall(flag, "ULTRA\n");
    try std.testing.expectEqualStrings("ultra", readFlagMode(gpa, flag).?);

    // Junk → null.
    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try toZ(&fb, flag));
    try writeSmall(flag, "rm -rf /");
    try std.testing.expect(readFlagMode(gpa, flag) == null);

    // Symlink → null (refused).
    _ = c.unlink(try toZ(&fb, flag));
    const target = try std.fs.path.join(gpa, &.{ dir_path, "secret.txt" });
    defer gpa.free(target);
    try writeSmall(target, "full");
    var tb: [std.fs.max_path_bytes]u8 = undefined;
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(c.symlink(try toZ(&tb, target), try toZ(&lb, flag)) == 0);
    try std.testing.expect(readFlagMode(gpa, flag) == null);

    _ = c.unlink(try toZ(&lb, flag));
    _ = c.unlink(try toZ(&tb, target));
}
