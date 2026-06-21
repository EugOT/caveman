//! Shared caveman/ponytail hook primitives — Zig 0.16, std.fs/std.Io.
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
//!   - the read/write/path helpers everything needs
//!
//! R6a — migrated the filesystem core off the libc C-ABI (c.Stat/c.O/c.S, raw
//! lstat/open/read/write/rename) onto the portable std.fs/std.Io surface so the
//! whole tree cross-compiles (x86_64-linux-gnu, x86_64-windows-gnu, native).
//!
//! Mechanism mapping (behavior is BYTE-IDENTICAL to the libc version):
//!   - lstat-classify            → Dir.statFile(io, p, .{ .follow_symlinks = false }).kind
//!   - O_NOFOLLOW open (read)    → Dir.openFile(io, p, .{ .follow_symlinks = false })
//!   - O_CREAT|O_EXCL temp write → Dir.createFile(io, p, .{ .exclusive = true, ... });
//!                                 O_EXCL refuses an existing path (incl. a symlink),
//!                                 the same clobber guard O_NOFOLLOW gave on the leaf.
//!   - atomic rename             → Dir.renameAbsolute(tmp, real, io)
//!   - mkdir 0700                → Dir.createDirAbsolute(io, dir, perms)  (ignore AlreadyExists)
//!   - realpath(3)               → Dir.realPathFileAbsolute(io, p, buf)
//!   - read(2) loop              → File.readPositional(io, iovec, offset) loop
//!   - write(2) loop             → File.writePositionalAll(io, bytes, offset)
//!   - fchmod 0600               → File.setPermissions(io, .fromMode(0600))  (POSIX only)
//!
//! THE ONE LIBC EXCEPTION — the uid-ownership compare. std.Io.File.Stat carries
//! no owner uid (inode/nlink/size/permissions/kind/times only), and std.posix.Stat
//! / std.c.Stat are `void` for the linux compile target, so there is no portable
//! std primitive that yields a file's owner uid. Per the migration contract we
//! keep ONE target-aware owner-uid probe (`pathUid`) plus `getuid` — implemented
//! through std's OWN target-correct syscall surfaces (linux `statx`, macOS/BSD
//! libc `stat`, Windows → null/no-uid). This is the only stat-by-uid path that
//! remains, and it is needed solely for the "symlinked flag dir must be owned by
//! the current uid" check that `resolveRealFlagDir` enforces. Everything else is
//! std.Io.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = std.c;

const is_windows = builtin.os.tag == .windows;

/// std.Io handle, threaded down from each binary's main. See `Io` below.
pub const Io = std.Io;

/// "caveman" or "ponytail" — selected at configure time by -Dtool.
pub const TOOL = build_options.tool;

/// Per-tool flag filename: ".<tool>-active".
pub const FLAG_NAME = "." ++ TOOL ++ "-active";

/// Pre-rendered savings-suffix filename written by caveman-stats.js.
pub const STATUSLINE_SUFFIX_NAME = "." ++ TOOL ++ "-statusline-suffix";

// libc decls still needed for the non-FS bits (env, stdio, time, getpid) that
// every hook binary already links libc for. The FS core no longer uses raw
// lstat/open/read/write/rename — those moved to std.Io (see file header).
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// THE ONE remaining stat — macOS/BSD libc stat(2) for the owner-uid compare
// (see file header). std.c exposes no `stat` fn and no portable Stat with a uid
// field, so we declare the extern locally and use the target's c.Stat (which
// carries .uid on darwin/bsd). Only referenced on non-linux/non-windows POSIX;
// on linux we use the statx syscall, on windows there is no uid.
const DarwinStat = if (builtin.os.tag == .windows or builtin.os.tag == .linux) void else c.Stat;
extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *DarwinStat) c_int;
extern "c" fn getuid() c.uid_t;

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

// ── std.Io construction ─────────────────────────────────────────────────────
//
// Each binary's main constructs a Threaded backend once and threads `io()` down
// to every FS fn (the 0.16 pattern, see start.zig:711). `defaultIo` packages
// that so callers need a single line:
//
//     var threaded = common.threaded();
//     defer threaded.deinit();
//     const io = threaded.io();
//
// The Threaded value must outlive the io handle, so it is returned by value and
// the caller owns its lifetime (deinit on scope exit).

pub fn threaded() std.Io.Threaded {
    // FS-only use: no argv0/environ needed; the failing allocator is fine for
    // the async paths we never touch. `page_allocator` keeps it allocation-free
    // at construction and never fails.
    return .init(std.heap.page_allocator, .{});
}

// ── path resolution ─────────────────────────────────────────────────────────

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

// ── portable FS primitives (std.Io) ─────────────────────────────────────────

const cwd = std.Io.Dir.cwd;

/// Permissions value for a 0600 file. On Windows (ACL model, no POSIX mode) we
/// fall back to the platform default — the 0600 bit is a POSIX-only property.
fn perm600() std.Io.File.Permissions {
    return if (is_windows) .default_file else .fromMode(0o600);
}

/// Permissions value for a 0700 dir. POSIX-only mode, default on Windows.
fn perm700() std.Io.File.Permissions {
    return if (is_windows) .default_dir else .fromMode(0o700);
}

/// statFile without following symlinks (the lstat equivalent). Returns the
/// portable std.Io.File.Stat (carries .kind), or null on any error / missing.
fn lstatKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const st = cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    return st.kind;
}

/// Owner uid of `path` following symlinks (the realpath-target owner). null on
/// Windows (no uid) or on any error. THE ONE libc/syscall stat that remains —
/// see the file header. Uses std's own per-target syscall surface so it stays
/// correct across native/linux/windows cross-compiles.
fn pathUid(path: [*:0]const u8) ?u32 {
    switch (builtin.os.tag) {
        .windows => return null,
        .linux => {
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            // flags = 0 → follow symlinks (matches the old stat(2) on realpath).
            const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .UID = true }, &sx);
            if (linux.errno(rc) != .SUCCESS) return null;
            return @intCast(sx.uid);
        },
        else => {
            // macOS / BSD: libc stat(2) with the target's c.Stat (which carries
            // a uid field on these targets). Declared locally; the only libc
            // stat in the file.
            var st: DarwinStat = undefined;
            if (stat(path, &st) != 0) return null;
            return @intCast(st.uid);
        },
    }
}

/// Current process uid. Windows has no uid; return 0 (never compared there).
fn currentUid() u32 {
    if (is_windows) return 0;
    return @intCast(getuid());
}

pub fn readFileAlloc(io: std.Io, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ?[]u8 {
    var f = cwd().openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer f.close(io);

    var out: std.ArrayList(u8) = .empty;
    var buf: [512]u8 = undefined;
    var offset: u64 = 0;
    while (out.items.len <= max_bytes) {
        var iov = [_][]u8{&buf};
        const n = f.readPositional(io, &iov, offset) catch {
            out.deinit(gpa);
            return null;
        };
        if (n == 0) {
            return out.toOwnedSlice(gpa) catch {
                out.deinit(gpa);
                return null;
            };
        }
        const next_len = out.items.len + n;
        if (next_len > max_bytes) {
            out.deinit(gpa);
            return null;
        }
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        offset += n;
    }
    out.deinit(gpa);
    return null;
}

pub fn isRegularFileNoSymlink(io: std.Io, path: []const u8) bool {
    return (lstatKind(io, path) orelse return false) == .file;
}

pub fn existsNoFollow(io: std.Io, path: []const u8) bool {
    return lstatKind(io, path) != null;
}

fn readModeFromConfigFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (!isRegularFileNoSymlink(io, path)) return null;
    const raw = readFileAlloc(io, gpa, path, 16 * 1024) orelse return null;
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

fn repoConfigMode(io: std.Io, gpa: std.mem.Allocator) ?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return null;
    var dir: []const u8 = std.mem.sliceTo(cwd_z, 0);

    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const nested = std.fs.path.join(gpa, &.{ dir, ".caveman", "config.json" }) catch return null;
        defer gpa.free(nested);
        if (readModeFromConfigFile(io, gpa, nested)) |mode| return mode;

        const flat = std.fs.path.join(gpa, &.{ dir, ".caveman.json" }) catch return null;
        defer gpa.free(flat);
        if (readModeFromConfigFile(io, gpa, flat)) |mode| return mode;

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
    return null;
}

fn userConfigMode(io: std.Io, gpa: std.mem.Allocator) ?[]const u8 {
    const path = if (getenv("XDG_CONFIG_HOME")) |xdg|
        std.fs.path.join(gpa, &.{ xdg, "caveman", "config.json" }) catch return null
    else if (getenv("HOME")) |home|
        std.fs.path.join(gpa, &.{ home, ".config", "caveman", "config.json" }) catch return null
    else if (getenv("APPDATA")) |appdata|
        std.fs.path.join(gpa, &.{ appdata, "caveman", "config.json" }) catch return null
    else
        return null;
    defer gpa.free(path);
    return readModeFromConfigFile(io, gpa, path);
}

pub fn getDefaultMode(io: std.Io, gpa: std.mem.Allocator) []const u8 {
    if (getenv("CAVEMAN_DEFAULT_MODE")) |mode| {
        if (canonicalMode(mode)) |m| return m;
    }
    if (repoConfigMode(io, gpa)) |mode| return mode;
    if (userConfigMode(io, gpa)) |mode| return mode;
    return "full";
}

/// Copy a slice into a fixed NUL-terminated buffer (for the few libc calls that
/// remain — env, the uid probe). Kept for the uid path + callers that still
/// build a sentinel path.
pub fn toZ(buf: []u8, s: []const u8) FlagError![*:0]const u8 {
    if (s.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// statFile (no-follow); true if it exists AND is a symlink (refuse-on-symlink).
pub fn isSymlink(io: std.Io, path: []const u8) bool {
    return (lstatKind(io, path) orelse return false) == .sym_link;
}

/// classify a path component as a (real) directory, a symlink, missing, or
/// other. Used to walk a directory chain refusing any non-directory link.
pub const Comp = enum { dir, symlink, missing, other };
pub fn classify(io: std.Io, path: []const u8) Comp {
    const kind = lstatKind(io, path) orelse return .missing;
    return switch (kind) {
        .sym_link => .symlink,
        .directory => .dir,
        else => .other,
    };
}

/// realpath a path into `out`; returns the resolved slice or null on failure.
/// `out` must be >= std.fs.max_path_bytes. Uses the cwd-relative form so it
/// accepts both absolute and relative inputs (no isAbsolute assert).
fn realpathInto(io: std.Io, path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const len = cwd().realPathFile(io, path, out) catch return null;
    return out[0..len];
}

/// True if reaching `dir` would pass through a symlink an attacker could plant
/// at ANY level below a trusted base — not just the immediate parent. Mirrors
/// the JS hooks fs-safe isAnyAncestorSymlink: anchor on the realpath of the
/// longest trusted base that lexically prefixes `dir` (absorbing benign system
/// links like /var above the user area), then statFile-walk each tail
/// component, refusing any symlinked or non-directory ancestor.
/// Strip trailing '/' chars (but keep a lone "/"). Mirrors how path.resolve
/// normalizes a base before a prefix comparison.
fn trimTrailingSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

pub fn ancestorUnsafe(io: std.Io, dir: []const u8) bool {
    // Trusted roots. Beyond HOME/TMPDIR/CLAUDE_CONFIG_DIR, honor the configured
    // agent roots (XDG, opencode, openclaw, nullclaw) so a legitimate config dir
    // outside HOME is not wrongly refused. (PR #8 / 511a8c1.)
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

    // Anchor on the realpath of the deepest EXISTING ancestor at/under `base`.
    // realpath returns an error on a nonexistent final component, so we must NOT
    // realpath `base` (or `dir`) directly — on first run the config dir does not
    // exist yet, which previously made this refuse every legitimate write. Climb
    // up from `base` until realpath succeeds; the components below that (still
    // nonexistent) are created by mkdir as real dirs, so they are safe.
    var anchor_buf: [std.fs.max_path_bytes]u8 = undefined;
    var existing = base;
    const anchor: []const u8 = realpathInto(io, existing, &anchor_buf) orelse blk: {
        while (true) {
            const up = std.fs.path.dirname(existing) orelse return true;
            if (up.len == existing.len) return true; // reached root, still unresolved
            existing = up;
            if (realpathInto(io, existing, &anchor_buf)) |a| break :blk a;
        }
    };

    // Walk every component from the resolved anchor down to `dir`, statFile-ing
    // each on the real anchor so an intermediate symlink surfaces as a component.
    const tail = dir[existing.len..]; // portion of dir below the resolved ancestor
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
        switch (classify(io, cur)) {
            .missing => return false, // tail not created yet → mkdir makes real dirs
            .symlink, .other => return true,
            .dir => {},
        }
    }
    return false;
}

/// Resolve the directory to write into, honoring a symlinked parent the same way
/// caveman-config.js safeWriteFlag does: a symlinked flag dir is ALLOWED iff its
/// realpath target is a directory owned by the current uid (the legitimate
/// `~/.claude`-as-symlink pattern); a symlink to a dir owned by another user, or
/// to a non-directory, is refused. Returns the real dir (owned slice in `out`),
/// or null to refuse. Mirrors the JS uid-ownership contract — NOT a recursive
/// ancestor walk (the JS only checks the immediate parent).
fn resolveRealFlagDir(io: std.Io, dir: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const kind = lstatKind(io, dir) orelse return null; // lstat error → refuse (JS returns)
    if (kind != .sym_link) {
        // Not a symlink: write directly into `dir`.
        if (dir.len >= out.len) return null;
        @memcpy(out[0..dir.len], dir);
        return out[0..dir.len];
    }
    // Symlinked parent: resolve and verify the target is a uid-owned directory.
    const real = realpathInto(io, dir, out) orelse return null;
    // statFile the realpath FOLLOWING symlinks (target must be a real dir).
    const rst = cwd().statFile(io, real, .{ .follow_symlinks = true }) catch return null;
    if (rst.kind != .directory) return null; // target not a dir
    // Owner-uid compare — the one remaining libc/syscall stat (see header).
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const rz = toZ(&rbuf, real) catch return null;
    const owner = pathUid(rz) orelse return null;
    if (owner != currentUid()) return null; // owned by another user → refuse
    return real;
}

/// Symlink-safe atomic flag write. Mirrors caveman-config.js safeWriteFlag:
/// mkdir -p the dir; allow a uid-owned symlinked parent (resolve it); refuse the
/// leaf flag file being a symlink (the real clobber vector); write a temp with
/// O_CREAT|O_EXCL (refuses an existing leaf incl. a symlink) at 0600, chmod
/// 0600, atomic rename onto the real flag path. Silent on all FS errors.
pub fn safeWriteFlag(io: std.Io, gpa: std.mem.Allocator, path: []const u8, content: []const u8) FlagError!void {
    const dir = std.fs.path.dirname(path) orelse ".";

    // Ensure parent exists (0700). Ignore errors (already-exists / race).
    cwd().createDir(io, dir, perm700()) catch {};

    var rdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real_dir = resolveRealFlagDir(io, dir, &rdbuf) orelse return error.ParentSymlinkRefused;

    // Real flag path = real_dir / basename(path).
    const base = std.fs.path.basename(path);
    const real_path = try std.fs.path.join(gpa, &.{ real_dir, base });
    defer gpa.free(real_path);

    // The flag file itself must never be a symlink (the actual clobber vector).
    if (isSymlink(io, real_path)) return error.SymlinkRefused;

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ real_path, c.getpid() });
    defer gpa.free(tmp);

    // O_CREAT|O_EXCL, mode 0600. O_EXCL fails (EEXIST) on any existing leaf,
    // INCLUDING a symlink, so it gives the same final-component clobber refusal
    // O_NOFOLLOW gave on the original create.
    var f = cwd().createFile(io, tmp, .{ .exclusive = true, .permissions = perm600() }) catch return error.OpenFailed;
    {
        defer f.close(io);
        if (!is_windows) f.setPermissions(io, perm600()) catch {}; // best-effort, matches JS fchmodSync
        f.writePositionalAll(io, content, 0) catch return error.WriteFailed;
    }

    cwd().rename(tmp, cwd(), real_path, io) catch {
        cwd().deleteFile(io, tmp) catch {};
        return error.RenameFailed;
    };
}

/// Symlink-safe, size-capped, whitelist-validated flag read.
/// Mirrors caveman-config.js readFlag: refuses symlinks, caps at 64 bytes,
/// lowercases + trims, returns the canonical mode or null on any anomaly.
pub const MAX_FLAG_BYTES = 64;
pub fn readFlagMode(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (!isRegularFileNoSymlink(io, path)) return null;
    const raw = readFileAlloc(io, gpa, path, MAX_FLAG_BYTES) orelse return null;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return canonicalMode(trimmed);
}

/// Read all of stdin into an owned buffer using raw read(2). Stdin is a stream,
/// not a path — keep the libc read here (no symlink surface, fd 0).
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

pub fn unlinkFlag(io: std.Io, path: []const u8) void {
    cwd().deleteFile(io, path) catch {};
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
/// appendFlag: refuse-on-symlink for both the target file and any ancestor of
/// its parent, ensure parent exists, write at end-of-file with the same
/// O_NOFOLLOW guard (open existing no-follow, or create exclusively), and
/// normalize the trailing newline (strip then add exactly one). Best-effort:
/// silent-fails on every filesystem error — history is never load-bearing.
pub fn appendHistory(io: std.Io, path: []const u8, line: []const u8) void {
    if (isSymlink(io, path)) return;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (ancestorUnsafe(io, dir)) return;

    cwd().createDir(io, dir, perm700()) catch {};

    // Open the existing file no-follow for append; if it does not exist, create
    // it exclusively (O_EXCL refuses a symlink leaf — same clobber guard).
    var f = open: {
        if (cwd().openFile(io, path, .{ .mode = .write_only, .follow_symlinks = false })) |existing| {
            break :open existing;
        } else |_| {
            break :open cwd().createFile(io, path, .{ .exclusive = true, .permissions = perm600() }) catch return;
        }
    };
    defer f.close(io);

    // Append offset = current size.
    const end = f.stat(io) catch return;
    const offset: u64 = end.size;

    // Mirror JS: String(line).replace(/\n$/, '') + '\n' — strip a single
    // trailing newline, then write the line plus exactly one newline.
    const body = if (line.len > 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
    f.writePositionalAll(io, body, offset) catch return;
    f.writePositionalAll(io, "\n", offset + body.len) catch return;
}

/// Symlink-safe history read. Returns the whole file as an owned buffer or null.
/// Mirrors caveman-config.js readHistory: refuse symlinks / non-regular files,
/// no size cap (history grows with use). Caller splits + parses lines.
pub fn readHistoryFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (isSymlink(io, path)) return null;
    if (!isRegularFileNoSymlink(io, path)) return null;
    var f = cwd().openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer f.close(io);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        var iov = [_][]u8{&buf};
        const n = f.readPositional(io, &iov, offset) catch {
            out.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        offset += n;
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

/// Make a unique temp dir via std.Io (matches the code under test).
pub fn makeTmpDir(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    const base = getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/zighooktest.{d}", .{ base, c.getpid() });
    cwd().createDir(io, dir, perm700()) catch {};
    return dir;
}

pub fn readSmall(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var iov = [_][]u8{&buf};
    const n = f.readPositional(io, &iov, 0) catch return error.ReadFailed;
    return gpa.dupe(u8, buf[0..n]);
}

pub fn writeSmall(io: std.Io, path: []const u8, content: []const u8) !void {
    cwd().deleteFile(io, path) catch {};
    var f = try cwd().createFile(io, path, .{ .exclusive = true, .permissions = perm600() });
    defer f.close(io);
    f.writePositionalAll(io, content, 0) catch return error.WriteFailed;
}

pub fn mkdirPath(io: std.Io, path: []const u8) !void {
    cwd().createDir(io, path, perm700()) catch {};
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

/// Plant a symlink for the tests (std.Io has symLinkAbsolute). Returns true on
/// success. POSIX-only in practice (Windows symlinks need privilege); the
/// symlink tests are guarded to POSIX hosts.
fn testSymlink(io: std.Io, target: []const u8, link: []const u8) bool {
    cwd().symLink(io, target, link, .{}) catch return false;
    return true;
}

test "getDefaultMode reads env before config" {
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const old_default = try saveEnv(gpa, "CAVEMAN_DEFAULT_MODE");
    defer if (old_default) |v| gpa.free(v);
    defer restoreEnv("CAVEMAN_DEFAULT_MODE", old_default);

    _ = setenv("CAVEMAN_DEFAULT_MODE", "ULTRA", 1);
    try std.testing.expectEqualStrings("ultra", getDefaultMode(io, gpa));

    _ = setenv("CAVEMAN_DEFAULT_MODE", "not-a-mode", 1);
    try std.testing.expect(!std.mem.eql(u8, getDefaultMode(io, gpa), "not-a-mode"));
}

test "getDefaultMode reads XDG user config" {
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const old_default = try saveEnv(gpa, "CAVEMAN_DEFAULT_MODE");
    defer if (old_default) |v| gpa.free(v);
    defer restoreEnv("CAVEMAN_DEFAULT_MODE", old_default);
    const old_xdg = try saveEnv(gpa, "XDG_CONFIG_HOME");
    defer if (old_xdg) |v| gpa.free(v);
    defer restoreEnv("XDG_CONFIG_HOME", old_xdg);

    _ = unsetenv("CAVEMAN_DEFAULT_MODE");

    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const xdg = try std.fs.path.join(gpa, &.{ dir_path, "xdg" });
    defer gpa.free(xdg);
    const caveman_dir = try std.fs.path.join(gpa, &.{ xdg, "caveman" });
    defer gpa.free(caveman_dir);
    const config = try std.fs.path.join(gpa, &.{ caveman_dir, "config.json" });
    defer gpa.free(config);

    try mkdirPath(io, xdg);
    try mkdirPath(io, caveman_dir);
    try writeSmall(io, config, "{\"defaultMode\":\"review\"}");

    const xdg_z = try gpa.dupeZ(u8, xdg);
    defer gpa.free(xdg_z);
    _ = setenv("XDG_CONFIG_HOME", xdg_z.ptr, 1);

    try std.testing.expectEqualStrings("review", getDefaultMode(io, gpa));
}

test "safeWriteFlag refuses symlinked target (clobber attack)" {
    if (is_windows) return error.SkipZigTest;
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim.txt" });
    defer gpa.free(victim);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active" });
    defer gpa.free(flag);

    // Create victim with SECRET via the code's own write helpers.
    try writeSmall(io, victim, "SECRET");

    try std.testing.expect(testSymlink(io, victim, flag)); // plant flag -> victim

    try std.testing.expectError(error.SymlinkRefused, safeWriteFlag(io, gpa, flag, "full"));

    const data = try readSmall(io, gpa, victim);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("SECRET", data); // untouched

    cwd().deleteFile(io, flag) catch {};
    cwd().deleteFile(io, victim) catch {};
}

test "safeWriteFlag writes mode on clean path" {
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active2" });
    defer gpa.free(flag);

    try safeWriteFlag(io, gpa, flag, "ultra");
    const data = try readSmall(io, gpa, flag);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("ultra", data);

    cwd().deleteFile(io, flag) catch {};
}

test "safeWriteFlag honors configured opencode root outside HOME" {
    // A legit config dir under $OPENCODE_CONFIG_DIR (not HOME/TMPDIR) must be a
    // trusted base — otherwise ancestorUnsafe refuses every write there. (PR #8.)
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const old_tmp = try saveEnv(gpa, "TMPDIR");
    defer if (old_tmp) |v| gpa.free(v);
    defer restoreEnv("TMPDIR", old_tmp);
    const old_opencode = try saveEnv(gpa, "OPENCODE_CONFIG_DIR");
    defer if (old_opencode) |v| gpa.free(v);
    defer restoreEnv("OPENCODE_CONFIG_DIR", old_opencode);

    _ = unsetenv("TMPDIR");

    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);
    const root = try std.fs.path.join(gpa, &.{ dir_path, "external-opencode" });
    defer gpa.free(root);
    try mkdirPath(io, root);

    const root_z = try gpa.dupeZ(u8, root);
    defer gpa.free(root_z);
    _ = setenv("OPENCODE_CONFIG_DIR", root_z.ptr, 1);

    const nested = try std.fs.path.join(gpa, &.{ root, "plugins", "caveman" });
    defer gpa.free(nested);
    try std.testing.expect(!ancestorUnsafe(io, nested));

    const settings = try std.fs.path.join(gpa, &.{ root, "opencode.json" });
    defer gpa.free(settings);
    try safeWriteFlag(io, gpa, settings, "{}\n");
    const data = try readSmall(io, gpa, settings);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{}\n", data);

    cwd().deleteFile(io, settings) catch {};
}

test "safeWriteFlag ALLOWS a uid-owned symlinked parent dir (JS contract)" {
    // Mirrors caveman-config.js: a symlinked flag dir is allowed iff its realpath
    // target is a directory owned by the current uid (the legitimate
    // ~/.claude-as-symlink pattern). The write lands in the real target dir.
    if (is_windows) return error.SkipZigTest;
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);

    const real = try std.fs.path.join(gpa, &.{ dir_path, "real" });
    defer gpa.free(real);
    const link = try std.fs.path.join(gpa, &.{ dir_path, "link" });
    defer gpa.free(link);

    try mkdirPath(io, real); // owned by this test's uid
    try std.testing.expect(testSymlink(io, real, link));

    // flag dir is the symlink `link` itself → realpath = real (uid-owned dir) → allowed.
    const flag = try std.fs.path.join(gpa, &.{ link, ".active3" });
    defer gpa.free(flag);
    try safeWriteFlag(io, gpa, flag, "full");

    // Written through to the real dir, not the symlink path.
    const real_flag = try std.fs.path.join(gpa, &.{ real, ".active3" });
    defer gpa.free(real_flag);
    const data = try readSmall(io, gpa, real_flag);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("full", data);

    cwd().deleteFile(io, real_flag) catch {};
    cwd().deleteFile(io, link) catch {};
}

test "readFlagMode whitelist + symlink refusal" {
    if (is_windows) return error.SkipZigTest;
    var th = threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(io, gpa);
    defer gpa.free(dir_path);

    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".readflag" });
    defer gpa.free(flag);

    // Valid mode, with trailing newline + uppercase → canonicalized.
    try writeSmall(io, flag, "ULTRA\n");
    try std.testing.expectEqualStrings("ultra", readFlagMode(io, gpa, flag).?);

    // Junk → null.
    cwd().deleteFile(io, flag) catch {};
    try writeSmall(io, flag, "rm -rf /");
    try std.testing.expect(readFlagMode(io, gpa, flag) == null);

    // Symlink → null (refused).
    cwd().deleteFile(io, flag) catch {};
    const target = try std.fs.path.join(gpa, &.{ dir_path, "secret.txt" });
    defer gpa.free(target);
    try writeSmall(io, target, "full");
    try std.testing.expect(testSymlink(io, target, flag));
    try std.testing.expect(readFlagMode(io, gpa, flag) == null);

    cwd().deleteFile(io, flag) catch {};
    cwd().deleteFile(io, target) catch {};
}
