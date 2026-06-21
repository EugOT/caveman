//! caveman init — Zig 0.16 port of src/tools/caveman-init.js.
//!
//! Drops the always-on caveman activation rule into a target repo for every IDE
//! agent we support. Idempotent, safe to re-run. Mirrors the JS contract:
//!
//!   caveman-init [target-dir] [--dry-run] [--force] [--only <agent>] [-h]
//!
//! Without args runs in cwd. Generates the default rule files for Cursor,
//! Windsurf, Cline, Copilot, opencode, and AGENTS.md. Explicit-only targets
//! (skill dirs, CLAUDE.md import bridge, .claw) install via `--only <alias>`.
//!
//! The rule body and skill body are @embedFile'd from the in-repo
//! sources-of-truth (src/rules/caveman-activate.md and skills/caveman/SKILL.md),
//! the same way activate.zig pins its ruleset — a standalone binary has no
//! adjacent source tree to read at runtime.
//!
//! Symlink-safe writes reuse common.zig (isSymlink / classify / ancestorUnsafe /
//! safeWriteFlag mechanics): refuse-on-symlink target, refuse symlinked parent,
//! atomic temp+rename. OpenClaw / NullClaw installers are DEFERRED to R4b (they
//! ride alongside the installer port); here they report unsupported-standalone
//! like the JS does when the helper module is absent.
//!
//! Filesystem core on std.fs/std.Io (statFile/openFile/createFile/createDir/
//! createDirPath/rename/deleteFile/deleteTree/symLink) so init cross-compiles
//! the same way common.zig's security core does. A std.Io.Threaded backend is
//! constructed once in main() and threaded down to every FS fn. The few libc
//! C-ABI calls that remain are the non-FS process/stdio surface common.zig also
//! keeps (env, getpid, getcwd, gettimeofday, write/read on fds) — not Stat/O/S
//! or path open/read/write, which now all route through std.Io.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const c = std.c;
const is_windows = builtin.os.tag == .windows;

// Embedded sources-of-truth. They live OUTSIDE the zig/ package root
// (src/rules/, skills/), so build.zig exposes them as named anonymous imports
// (addInitEmbeds) rather than a cross-package relative @embedFile. Importing a
// non-Zig file module yields its raw bytes as a `[]const u8`. Mirrors
// caveman-init.js loadRuleBody()/loadSkillBody() preferring the in-repo files.
const RULE_BODY_RAW = @embedFile("rule_body");
const SKILL_BODY_RAW = @embedFile("skill_body");

const SENTINEL = "Respond terse like smart caveman";

// JSON.stringify(command)-style mode labels for the skill frontmatter come baked
// into SKILL.md already; we just trim + normalize the trailing newline.

const Mode = enum {
    replace, // overwrite-on-force, frontmatter + rule body
    append, // append rule body if sentinel absent
    skill, // write SKILL.md body
    import_agents, // CLAUDE.md @AGENTS.md bridge
    installer_openclaw,
    installer_nullclaw,
};

const Agent = struct {
    id: []const u8,
    file: ?[]const u8 = null,
    description: ?[]const u8 = null,
    frontmatter: []const u8 = "",
    mode: Mode,
    is_default: bool = true,
    aliases: []const []const u8 = &.{},
};

const UNIVERSAL_AGENT_ALIASES = [_][]const u8{
    "agents",     "antigravity", "antigravity-app", "antigravity-cli",
    "claude",     "claude-code", "claude-desktop",  "claw",
    "codex",      "codex-app",   "codex-cli",       "goclaw",
    "hermes",     "nullclaw",    "opencode",        "openclaw",
    "perplexity", "pi",          "pz",              "walcode",
    "walkode",    "warp",        "warp-preview",    "warppreview",
    "zeroclaw",
};
const CLAUDE_COMPAT_ALIASES = [_][]const u8{ "claude", "claude-code", "claude-desktop" };
const CODEX_STYLE_SKILL_ALIASES = [_][]const u8{
    "codex", "codex-app", "codex-cli", "claw", "goclaw", "walcode", "walkode", "zeroclaw",
};
const CLAW_ALIASES = [_][]const u8{ "claw", "goclaw", "walcode", "walkode", "zeroclaw" };
const PI_ALIASES = [_][]const u8{"pi"};
const PZ_ALIASES = [_][]const u8{"pz"};

const CURSOR_FM = "---\ndescription: \"Caveman mode — terse communication, ~75% fewer tokens, full technical accuracy\"\nalwaysApply: true\n---\n\n";
const WINDSURF_FM = "---\ntrigger: always_on\n---\n\n";

const AGENTS = [_]Agent{
    .{ .id = "cursor", .file = ".cursor/rules/caveman.mdc", .frontmatter = CURSOR_FM, .mode = .replace },
    .{ .id = "windsurf", .file = ".windsurf/rules/caveman.md", .frontmatter = WINDSURF_FM, .mode = .replace },
    .{ .id = "cline", .file = ".clinerules/caveman.md", .frontmatter = "", .mode = .replace },
    .{ .id = "copilot", .file = ".github/copilot-instructions.md", .frontmatter = "", .mode = .append },
    .{ .id = "opencode", .file = ".opencode/AGENTS.md", .frontmatter = "", .mode = .append },
    .{ .id = "agents", .file = "AGENTS.md", .frontmatter = "", .mode = .append, .aliases = &UNIVERSAL_AGENT_ALIASES },
    .{ .id = "agents-skill", .file = ".agents/skills/caveman/SKILL.md", .mode = .skill, .is_default = false, .aliases = &UNIVERSAL_AGENT_ALIASES },
    .{ .id = "claude-import", .file = "CLAUDE.md", .mode = .import_agents, .is_default = false, .aliases = &CLAUDE_COMPAT_ALIASES },
    .{ .id = "codex-skill", .file = ".codex/skills/caveman/SKILL.md", .mode = .skill, .is_default = false, .aliases = &CODEX_STYLE_SKILL_ALIASES },
    .{ .id = "claude-skill", .file = ".claude/skills/caveman/SKILL.md", .mode = .skill, .is_default = false, .aliases = &CLAUDE_COMPAT_ALIASES },
    .{ .id = "pi-skill", .file = ".pi/skills/caveman/SKILL.md", .mode = .skill, .is_default = false, .aliases = &PI_ALIASES },
    .{ .id = "pz-skill", .file = ".pz/skills/caveman/SKILL.md", .mode = .skill, .is_default = false, .aliases = &PZ_ALIASES },
    .{ .id = "claw", .file = ".claw/instructions.md", .frontmatter = "", .mode = .append, .is_default = false, .aliases = &CLAW_ALIASES },
    .{ .id = "openclaw", .description = "~/.openclaw/workspace/{skills/caveman/, SOUL.md}", .mode = .installer_openclaw },
    .{ .id = "nullclaw", .description = "~/.nullclaw/workspace/skills/caveman/SKILL.md", .mode = .installer_nullclaw, .is_default = false },
};

// ── Rule / skill bodies (trimEnd + single newline) ─────────────────────────
fn trimmedBody(comptime raw: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, raw, " \t\r\n");
    return t ++ "\n";
}
const RULE_BODY = trimmedBody(RULE_BODY_RAW);
const SKILL_BODY = trimmedBody(SKILL_BODY_RAW);

const IMPORT_BODY = "@AGENTS.md\n\n<!-- caveman-import: Respond terse like smart caveman. Keep Claude-compatible harnesses aligned with AGENTS.md. -->\n";

fn agentBody(gpa: std.mem.Allocator, agent: Agent) ![]u8 {
    switch (agent.mode) {
        .skill => return gpa.dupe(u8, SKILL_BODY),
        .import_agents => return gpa.dupe(u8, IMPORT_BODY),
        else => {
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ agent.frontmatter, RULE_BODY });
        },
    }
}

// ── Symlink-safe write (mirrors writeFileSafe + unsafeWriteReason in JS) ────
// We reuse the security primitives in common.zig. The JS resolves the target
// path and refuses: symlinked target, target-is-directory, symlinked/non-dir
// ancestor under the root, then mkdir -p, re-check, atomic temp+rename (mode
// 0644). common.safeWriteFlag does the symlink/ancestor refusal + atomic
// rename but with 0600 + a different ancestor anchor; here we need 0644 and the
// caveman-init root-anchored ancestor walk, so we implement a focused writer.

const WriteError = error{
    SymlinkRefused,
    UnsafeParent,
    TargetNotFile,
    OpenFailed,
    WriteFailed,
    RenameFailed,
    PathTooLong,
} || std.mem.Allocator.Error;

/// True if writing `target` would pass through a symlink/non-dir ANYWHERE in the
/// chain from `root` down to the parent dir. Mirrors unsafeParentReason: anchor
/// at root, walk each component of relative(root, parent), refuse symlink or
/// non-directory. Missing components are fine (mkdir will create real dirs).
///
/// Both `target` and `root` are absolute, normalized paths (resolveAbs +
/// path.join with no `..`), so we compute the tail of `parent` under `root` by
/// a lexical prefix check rather than std.fs.path.relative (whose 0.16 signature
/// now threads cwd/environ for the Io surface). `gpa` is unused but kept in the
/// signature so callers don't need to special-case allocation.
fn unsafeParent(io: std.Io, gpa: std.mem.Allocator, target: []const u8, root: []const u8) bool {
    _ = gpa;
    const parent = std.fs.path.dirname(target) orelse return false;

    // Strip a trailing slash off root for a clean prefix comparison.
    const root_clean = if (root.len > 1 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;

    // parent must equal root or be strictly under it. Anything else is outside
    // the safe root → refuse.
    var tail: []const u8 = undefined;
    if (std.mem.eql(u8, parent, root_clean)) {
        tail = "";
    } else if (parent.len > root_clean.len and
        std.mem.startsWith(u8, parent, root_clean) and
        parent[root_clean.len] == '/')
    {
        tail = parent[root_clean.len + 1 ..];
    } else {
        return true; // outside safe root
    }

    // Root itself must be a real dir if it exists.
    switch (common.classify(io, root_clean)) {
        .symlink, .other => return true,
        else => {},
    }
    if (tail.len == 0) return false;

    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (root_clean.len >= cur_buf.len) return true;
    @memcpy(cur_buf[0..root_clean.len], root_clean);
    var cur_len = root_clean.len;

    var it = std.mem.tokenizeScalar(u8, tail, '/');
    while (it.next()) |part| {
        if (cur_len + 1 + part.len >= cur_buf.len) return true;
        cur_buf[cur_len] = '/';
        @memcpy(cur_buf[cur_len + 1 ..][0..part.len], part);
        cur_len += 1 + part.len;
        switch (common.classify(io, cur_buf[0..cur_len])) {
            .missing => return false, // not created yet → mkdir makes real dirs
            .symlink, .other => return true,
            .dir => {},
        }
    }
    return false;
}

/// mkdir -p each component of `dir` (0755), best-effort.
///
/// STDLIB FIRST: std.Io.Dir.createDirPathStatus is the recursive mkdir -p
/// primitive (createDirPath with an explicit Permissions). Best-effort like the
/// old c.mkdir loop — every error is swallowed (a pre-existing dir, a race, or a
/// refused component all leave the later symlink-safe re-checks to reject the
/// write). 0o755 mode preserved exactly via Permissions.fromMode.
fn mkdirP(io: std.Io, dir: []const u8) void {
    if (dir.len == 0) return;
    const perms: std.Io.File.Permissions = if (is_windows) .default_dir else .fromMode(0o755);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, perms) catch {};
}

fn writeFileSafe(io: std.Io, gpa: std.mem.Allocator, target: []const u8, content: []const u8, root: []const u8) WriteError!void {
    if (common.isSymlink(io, target)) return error.SymlinkRefused;
    if (unsafeParent(io, gpa, target, root)) return error.UnsafeParent;

    const dir = std.fs.path.dirname(target) orelse ".";
    mkdirP(io, dir);

    if (common.isSymlink(io, target)) return error.SymlinkRefused;
    if (unsafeParent(io, gpa, target, root)) return error.UnsafeParent;

    const tmp = try std.fmt.allocPrint(gpa, "{s}/.{s}.{d}.{d}.tmp", .{
        dir,
        std.fs.path.basename(target),
        c.getpid(),
        common.nowMillis(),
    });
    defer gpa.free(tmp);

    const cwd = std.Io.Dir.cwd();
    // O_CREAT|O_EXCL ("wx"), mode 0644. O_EXCL refuses an existing leaf (incl. a
    // symlink), the same clobber guard the raw open had.
    var f = cwd.createFile(io, tmp, .{
        .exclusive = true,
        .permissions = if (is_windows) .default_file else .fromMode(0o644),
    }) catch return error.OpenFailed;
    {
        f.writePositionalAll(io, content, 0) catch {
            f.close(io);
            cwd.deleteFile(io, tmp) catch {};
            return error.WriteFailed;
        };
        f.close(io);
    }

    cwd.rename(tmp, cwd, target, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return error.RenameFailed;
    };
}

// ── Per-agent processing (mirrors processAgent) ────────────────────────────
const Result = struct {
    status: []const u8,
    label: []const u8,
    detail: ?[]const u8 = null,
};

const Opts = struct {
    dry_run: bool = false,
    force: bool = false,
    only: std.ArrayList([]const u8) = .empty,
    target: []const u8 = "",
    help: bool = false,
};

fn lstatExists(io: std.Io, path: []const u8) bool {
    return common.classify(io, path) != .missing;
}

fn isSymlinkPath(io: std.Io, path: []const u8) bool {
    return common.classify(io, path) == .symlink;
}

fn isRegularFile(io: std.Io, path: []const u8) bool {
    return common.isRegularFileNoSymlink(io, path);
}

fn readWholeFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    // No symlink follow; cap large but generous.
    return common.readFileAlloc(io, gpa, path, 4 * 1024 * 1024);
}

fn processAgent(io: std.Io, gpa: std.mem.Allocator, agent: Agent, opts: *const Opts) !Result {
    if (agent.mode == .installer_openclaw) {
        return .{
            .status = "unsupported-standalone",
            .label = "x",
            .detail = "~/.openclaw/workspace (installer deferred to R4b — use the JS path: npx -y github:JuliusBrussee/caveman -- --only openclaw)",
        };
    }
    if (agent.mode == .installer_nullclaw) {
        return .{
            .status = "unsupported-standalone",
            .label = "x",
            .detail = "~/.nullclaw/workspace (installer deferred to R4b — use the JS path: npx -y github:JuliusBrussee/caveman -- --only nullclaw)",
        };
    }

    const full = try std.fs.path.join(gpa, &.{ opts.target, agent.file.? });
    defer gpa.free(full);

    const target_exists = lstatExists(io, full);
    if (isSymlinkPath(io, full)) return .{ .status = "skipped-symlink", .label = "!" };
    if (target_exists and !isRegularFile(io, full)) return .{ .status = "skipped-non-file", .label = "?" };
    if (unsafeParent(io, gpa, full, opts.target)) return .{ .status = "skipped-unsafe-parent", .label = "!" };

    if (!target_exists) {
        if (!opts.dry_run) {
            const body = try agentBody(gpa, agent);
            defer gpa.free(body);
            writeFileSafe(io, gpa, full, body, opts.target) catch |e| {
                return mapWriteErr(e);
            };
        }
        return .{ .status = "added", .label = "+" };
    }

    const existing = readWholeFile(io, gpa, full) orelse return .{ .status = "skipped-non-file", .label = "?" };
    defer gpa.free(existing);

    if (agent.mode == .import_agents and hasAgentsImport(existing)) {
        return .{ .status = "skipped-already-installed", .label = "=" };
    }
    if (agent.mode != .import_agents and std.mem.indexOf(u8, existing, SENTINEL) != null) {
        return .{ .status = "skipped-already-installed", .label = "=" };
    }

    if (agent.mode == .append or agent.mode == .import_agents) {
        if (!opts.dry_run) {
            const body = try agentBody(gpa, agent);
            defer gpa.free(body);
            const sep = appendSeparator(existing);
            const merged = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ existing, sep, body });
            defer gpa.free(merged);
            writeFileSafe(io, gpa, full, merged, opts.target) catch |e| return mapWriteErr(e);
        }
        return .{ .status = "appended", .label = "~" };
    }

    if (opts.force) {
        if (!opts.dry_run) {
            const body = try agentBody(gpa, agent);
            defer gpa.free(body);
            writeFileSafe(io, gpa, full, body, opts.target) catch |e| return mapWriteErr(e);
        }
        return .{ .status = "overwritten", .label = "!" };
    }

    return .{ .status = "skipped-exists", .label = "?" };
}

fn mapWriteErr(e: WriteError) Result {
    return switch (e) {
        error.SymlinkRefused => .{ .status = "skipped-symlink", .label = "!" },
        error.UnsafeParent => .{ .status = "skipped-unsafe-parent", .label = "!" },
        else => .{ .status = "skipped-write-error", .label = "?" },
    };
}

// JS: /(^|\n)@AGENTS\.md(\n|$)/
fn hasAgentsImport(text: []const u8) bool {
    const needle = "@AGENTS.md";
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, text, idx, needle)) |pos| {
        const before_ok = pos == 0 or text[pos - 1] == '\n';
        const after = pos + needle.len;
        const after_ok = after == text.len or text[after] == '\n';
        if (before_ok and after_ok) return true;
        idx = pos + 1;
    }
    return false;
}

// JS: existing.endsWith("\n\n") ? "" : existing.endsWith("\n") ? "\n" : "\n\n"
fn appendSeparator(existing: []const u8) []const u8 {
    if (std.mem.endsWith(u8, existing, "\n\n")) return "";
    if (std.mem.endsWith(u8, existing, "\n")) return "\n";
    return "\n\n";
}

// ── Agent resolution (mirrors resolveAgents + normalizeAgentId) ────────────
fn normalizeAgentId(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, id, " \t\r\n");
    const out = try gpa.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, i| {
        const lower = std.ascii.toLower(ch);
        out[i] = if (lower == '_') '-' else lower;
    }
    return out;
}

fn agentMatches(agent: Agent, id: []const u8) bool {
    if (std.mem.eql(u8, agent.id, id)) return true;
    for (agent.aliases) |a| {
        if (std.mem.eql(u8, a, id)) return true;
    }
    return false;
}

const ResolveError = error{UnknownAgent} || std.mem.Allocator.Error;

fn resolveAgents(gpa: std.mem.Allocator, only: []const []const u8, out: *std.ArrayList(Agent)) ResolveError!void {
    if (only.len == 0) {
        for (AGENTS) |agent| {
            if (agent.is_default) try out.append(gpa, agent);
        }
        return;
    }
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    var unknown: std.ArrayList([]const u8) = .empty;
    defer unknown.deinit(gpa);

    for (only) |raw| {
        const id = try normalizeAgentId(gpa, raw);
        defer gpa.free(id);
        var matched = false;
        for (AGENTS) |agent| {
            if (!agentMatches(agent, id)) continue;
            matched = true;
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, agent.id)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try seen.append(gpa, agent.id);
            try out.append(gpa, agent);
        }
        if (!matched) try unknown.append(gpa, raw);
    }
    if (unknown.items.len > 0) return error.UnknownAgent;
}

// ── Arg parsing (mirrors parseArgs) ────────────────────────────────────────
const ParseArgError = error{ OnlyNeedsValue, Alloc };

fn resolveAbs(gpa: std.mem.Allocator, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return gpa.dupe(u8, p);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return gpa.dupe(u8, p);
    const cwd = std.mem.sliceTo(cwd_z, 0);
    return std.fs.path.resolve(gpa, &.{ cwd, p });
}

// ── main ───────────────────────────────────────────────────────────────────
// 0.16 entry shape: the no-alloc POSIX arg iterator (init, not std.Io) keeps us
// on the libc C-ABI surface like the rest of the hook tree (stats.zig).
pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // Construct the std.Io backend once; thread it down to every FS fn.
    var threaded = common.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    // Collect argv (after argv0) so the parse loop can do its --only lookahead.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    {
        var it = init.args.iterate();
        defer it.deinit();
        _ = it.skip(); // argv0
        // dupe into the arena — iterator storage is freed at it.deinit().
        while (it.next()) |a| try argv.append(gpa, try gpa.dupe(u8, a));
    }

    var opts: Opts = .{};
    var target_set = false;

    var i: usize = 0;
    while (i < argv.items.len) : (i += 1) {
        const a = argv.items[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--only")) {
            i += 1;
            if (i >= argv.items.len or std.mem.startsWith(u8, argv.items[i], "--")) {
                writeStderr("--only requires an agent id\n");
                std.process.exit(2);
            }
            try opts.only.append(gpa, argv.items[i]);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            opts.target = try resolveAbs(gpa, a);
            target_set = true;
        }
    }
    if (!target_set) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse {
            writeStderr("cannot resolve cwd\n");
            std.process.exit(2);
        };
        opts.target = try gpa.dupe(u8, std.mem.sliceTo(cwd_z, 0));
    }

    if (opts.help) {
        try printHelp(gpa);
        return;
    }

    {
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(gpa);
        try hdr.appendSlice(gpa, "🪨 caveman init — ");
        try hdr.appendSlice(gpa, opts.target);
        if (opts.dry_run) try hdr.appendSlice(gpa, " (dry run)");
        try hdr.appendSlice(gpa, "\n\n");
        writeStdout(hdr.items);
    }

    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    resolveAgents(gpa, opts.only.items, &selected) catch {
        // Build the unknown-agent error message like the JS.
        try printUnknownAgent(gpa, opts.only.items);
        std.process.exit(2);
    };

    var added: usize = 0;
    var appended: usize = 0;
    var overwritten: usize = 0;
    var skipped: usize = 0;

    for (selected.items) |agent| {
        const result = try processAgent(io, gpa, agent, &opts);
        const target = agent.file orelse result.detail orelse agent.description orelse agent.id;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        try line.appendSlice(gpa, "  ");
        try line.appendSlice(gpa, result.label);
        try line.appendSlice(gpa, " ");
        try line.appendSlice(gpa, target);
        try line.appendSlice(gpa, " (");
        try line.appendSlice(gpa, result.status);
        try line.appendSlice(gpa, ")\n");
        writeStdout(line.items);

        if (std.mem.eql(u8, result.status, "added") or
            std.mem.eql(u8, result.status, "installed") or
            std.mem.eql(u8, result.status, "would-add"))
        {
            added += 1;
        } else if (std.mem.eql(u8, result.status, "appended")) {
            appended += 1;
        } else if (std.mem.eql(u8, result.status, "overwritten")) {
            overwritten += 1;
        } else {
            skipped += 1;
        }
    }

    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(gpa);
    const s = try std.fmt.allocPrint(gpa, "\n{d} added, {d} appended, {d} overwritten, {d} skipped\n", .{ added, appended, overwritten, skipped });
    defer gpa.free(s);
    writeStdout(s);
    if (opts.dry_run) writeStdout("(dry run — no files were written)\n");
}

fn printHelp(gpa: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\caveman init — drop always-on caveman rule into a target repo
        \\
        \\Usage: caveman-init [target-dir] [--dry-run] [--force] [--only <agent>]
        \\
        \\Defaults to current working directory. Idempotent — safe to re-run.
        \\
        \\Targets installed:
        \\
    );
    for (AGENTS) |a| {
        const file = a.file orelse a.description orelse "";
        const explicit = if (!a.is_default) " (explicit)" else "";
        try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, a.id);
        // pad id to width 13 like a.id.padEnd(13)
        if (a.id.len < 13) {
            var k: usize = a.id.len;
            while (k < 13) : (k += 1) try out.append(gpa, ' ');
        }
        try out.appendSlice(gpa, " ");
        try out.appendSlice(gpa, file);
        try out.appendSlice(gpa, explicit);
        if (a.aliases.len > 0) {
            try out.appendSlice(gpa, " aliases: ");
            for (a.aliases, 0..) |al, idx| {
                if (idx > 0) try out.appendSlice(gpa, ", ");
                try out.appendSlice(gpa, al);
            }
        }
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa,
        \\
        \\Flags:
        \\  --dry-run   show what would change, do not write
        \\  --force     overwrite existing rule files (default: skip)
        \\  --only <id> only install for one agent or alias (repeatable)
        \\
    );
    writeStdout(out.items);
}

fn printUnknownAgent(gpa: std.mem.Allocator, only: []const []const u8) !void {
    // Recompute which were unknown (resolveAgents only signals the condition).
    var unknown: std.ArrayList([]const u8) = .empty;
    defer unknown.deinit(gpa);
    for (only) |raw| {
        const id = try normalizeAgentId(gpa, raw);
        defer gpa.free(id);
        var matched = false;
        for (AGENTS) |agent| {
            if (agentMatches(agent, id)) {
                matched = true;
                break;
            }
        }
        if (!matched) try unknown.append(gpa, raw);
    }
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    try msg.appendSlice(gpa, "unknown agent: ");
    for (unknown.items, 0..) |u, idx| {
        if (idx > 0) try msg.appendSlice(gpa, ", ");
        try msg.appendSlice(gpa, u);
    }
    try msg.append(gpa, '\n');
    writeStderr(msg.items);
}

fn writeStdout(bytes: []const u8) void {
    common.writeStdout(bytes);
}
fn writeStderr(bytes: []const u8) void {
    common.writeStderr(bytes);
}

// ── Tests (mirror tests/test_caveman_init.js) ──────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(common);
}

fn tmpRepo(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    const base = common.getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/caveman-init-zig.{d}.{d}", .{ base, c.getpid(), common.nowMillis() });
    // STDLIB FIRST: single-level mkdir 0755 via std.Io.Dir.createDir (best-effort,
    // ignore AlreadyExists / races — same as the old c.mkdir whose return we dropped).
    const perms: std.Io.File.Permissions = if (is_windows) .default_dir else .fromMode(0o755);
    std.Io.Dir.cwd().createDir(io, dir, perms) catch {};
    return dir;
}

fn runDefaults(io: std.Io, gpa: std.mem.Allocator, target: []const u8, opts_in: Opts) !struct { added: usize, appended: usize, overwritten: usize, skipped: usize } {
    var opts = opts_in;
    opts.target = target;
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    var added: usize = 0;
    var appended: usize = 0;
    var overwritten: usize = 0;
    var skipped: usize = 0;
    for (selected.items) |agent| {
        const r = try processAgent(io, gpa, agent, &opts);
        if (std.mem.eql(u8, r.status, "added") or std.mem.eql(u8, r.status, "would-add") or std.mem.eql(u8, r.status, "installed")) {
            added += 1;
        } else if (std.mem.eql(u8, r.status, "appended")) {
            appended += 1;
        } else if (std.mem.eql(u8, r.status, "overwritten")) {
            overwritten += 1;
        } else {
            skipped += 1;
        }
    }
    return .{ .added = added, .appended = appended, .overwritten = overwritten, .skipped = skipped };
}

fn readFileZ(io: std.Io, gpa: std.mem.Allocator, target: []const u8, rel: []const u8) !?[]u8 {
    const full = try std.fs.path.join(gpa, &.{ target, rel });
    defer gpa.free(full);
    return common.readFileAlloc(io, gpa, full, 1024 * 1024);
}

fn exists(io: std.Io, gpa: std.mem.Allocator, target: []const u8, rel: []const u8) !bool {
    const full = try std.fs.path.join(gpa, &.{ target, rel });
    defer gpa.free(full);
    return common.classify(io, full) != .missing;
}

test "greenfield: creates all default rule files with frontmatter" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const counts = try runDefaults(io, gpa, tmp, .{});
    // 6 default file targets + openclaw installer (unsupported-standalone → skipped).
    try testing.expectEqual(@as(usize, 6), counts.added);

    const cursor = (try readFileZ(io, gpa, tmp, ".cursor/rules/caveman.mdc")).?;
    defer gpa.free(cursor);
    try testing.expect(std.mem.indexOf(u8, cursor, "alwaysApply: true") != null);
    try testing.expect(std.mem.indexOf(u8, cursor, SENTINEL) != null);

    const windsurf = (try readFileZ(io, gpa, tmp, ".windsurf/rules/caveman.md")).?;
    defer gpa.free(windsurf);
    try testing.expect(std.mem.indexOf(u8, windsurf, "trigger: always_on") != null);

    const cline = (try readFileZ(io, gpa, tmp, ".clinerules/caveman.md")).?;
    defer gpa.free(cline);
    try testing.expect(std.mem.startsWith(u8, cline, "Respond terse"));

    const copilot = (try readFileZ(io, gpa, tmp, ".github/copilot-instructions.md")).?;
    defer gpa.free(copilot);
    try testing.expect(std.mem.indexOf(u8, copilot, "Respond terse") != null);

    const agents = (try readFileZ(io, gpa, tmp, "AGENTS.md")).?;
    defer gpa.free(agents);
    try testing.expect(std.mem.indexOf(u8, agents, "Respond terse") != null);

    const opencode = (try readFileZ(io, gpa, tmp, ".opencode/AGENTS.md")).?;
    defer gpa.free(opencode);
    try testing.expect(std.mem.indexOf(u8, opencode, "Respond terse") != null);

    cleanup(io, tmp);
}

test "idempotent: re-run skips all default file targets" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    _ = try runDefaults(io, gpa, tmp, .{});
    const counts = try runDefaults(io, gpa, tmp, .{});
    try testing.expectEqual(@as(usize, 0), counts.added);
    // 6 repo files skipped-already-installed + openclaw unsupported-standalone.
    try testing.expectEqual(@as(usize, 7), counts.skipped);

    cleanup(io, tmp);
}

test "append mode: existing AGENTS.md gets caveman appended not replaced" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const agents_path = try std.fs.path.join(gpa, &.{ tmp, "AGENTS.md" });
    defer gpa.free(agents_path);
    try common.writeSmall(io, agents_path, "# My project\n\nDo not delete me.\n");

    _ = try runDefaults(io, gpa, tmp, .{});
    const agents = (try readFileZ(io, gpa, tmp, "AGENTS.md")).?;
    defer gpa.free(agents);
    try testing.expect(std.mem.indexOf(u8, agents, "Do not delete me") != null);
    try testing.expect(std.mem.indexOf(u8, agents, SENTINEL) != null);

    cleanup(io, tmp);
}

test "skip mode: existing .cursor rule not overwritten without --force" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const dir = try std.fs.path.join(gpa, &.{ tmp, ".cursor", "rules" });
    defer gpa.free(dir);
    mkdirP(io, dir);
    const file = try std.fs.path.join(gpa, &.{ dir, "caveman.mdc" });
    defer gpa.free(file);
    try common.writeSmall(io, file, "# original\nDo not delete me.\n");

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "cursor");
    defer opts.only.deinit(gpa);

    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    const r = try processAgent(io, gpa, selected.items[0], &opts);
    try testing.expectEqualStrings("skipped-exists", r.status);

    const after = (try readFileZ(io, gpa, tmp, ".cursor/rules/caveman.mdc")).?;
    defer gpa.free(after);
    try testing.expectEqualStrings("# original\nDo not delete me.\n", after);

    cleanup(io, tmp);
}

test "--force overwrites existing rule file" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const dir = try std.fs.path.join(gpa, &.{ tmp, ".cursor", "rules" });
    defer gpa.free(dir);
    mkdirP(io, dir);
    const file = try std.fs.path.join(gpa, &.{ dir, "caveman.mdc" });
    defer gpa.free(file);
    try common.writeSmall(io, file, "# original\n");

    var opts: Opts = .{ .target = tmp, .force = true };
    try opts.only.append(gpa, "cursor");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    const r = try processAgent(io, gpa, selected.items[0], &opts);
    try testing.expectEqualStrings("overwritten", r.status);

    const after = (try readFileZ(io, gpa, tmp, ".cursor/rules/caveman.mdc")).?;
    defer gpa.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "alwaysApply: true") != null);
    try testing.expect(std.mem.indexOf(u8, after, "Respond terse") != null);

    cleanup(io, tmp);
}

test "--dry-run announces but writes nothing" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const counts = try runDefaults(io, gpa, tmp, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 6), counts.added);
    try testing.expect(!(try exists(io, gpa, tmp, ".cursor")));
    try testing.expect(!(try exists(io, gpa, tmp, ".windsurf")));
    try testing.expect(!(try exists(io, gpa, tmp, ".clinerules")));
    try testing.expect(!(try exists(io, gpa, tmp, ".github/copilot-instructions.md")));
    try testing.expect(!(try exists(io, gpa, tmp, ".opencode")));
    try testing.expect(!(try exists(io, gpa, tmp, "AGENTS.md")));

    cleanup(io, tmp);
}

test "--only cline filters to one target" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "cline");
    defer opts.only.deinit(gpa);
    const counts = try runDefaults(io, gpa, tmp, opts);
    try testing.expectEqual(@as(usize, 1), counts.added);
    try testing.expect(try exists(io, gpa, tmp, ".clinerules/caveman.md"));
    try testing.expect(!(try exists(io, gpa, tmp, ".cursor")));

    cleanup(io, tmp);
}

test "--only codex-app writes universal contract + agents skill + codex skill" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "codex-app");
    defer opts.only.deinit(gpa);
    const counts = try runDefaults(io, gpa, tmp, opts);
    try testing.expectEqual(@as(usize, 3), counts.added);
    try testing.expect(try exists(io, gpa, tmp, "AGENTS.md"));
    try testing.expect(try exists(io, gpa, tmp, ".agents/skills/caveman/SKILL.md"));

    const skill = (try readFileZ(io, gpa, tmp, ".codex/skills/caveman/SKILL.md")).?;
    defer gpa.free(skill);
    try testing.expect(std.mem.startsWith(u8, skill, "---\nname: caveman"));
    try testing.expect(std.mem.indexOf(u8, skill, SENTINEL) != null);
    try testing.expect(!(try exists(io, gpa, tmp, ".cursor")));

    cleanup(io, tmp);
}

test "--only walcode writes universal, claw, agents skill, codex skill" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "walcode");
    defer opts.only.deinit(gpa);
    const counts = try runDefaults(io, gpa, tmp, opts);
    try testing.expectEqual(@as(usize, 4), counts.added);
    try testing.expect(try exists(io, gpa, tmp, "AGENTS.md"));
    try testing.expect(try exists(io, gpa, tmp, ".agents/skills/caveman/SKILL.md"));
    try testing.expect(try exists(io, gpa, tmp, ".codex/skills/caveman/SKILL.md"));
    const instr = (try readFileZ(io, gpa, tmp, ".claw/instructions.md")).?;
    defer gpa.free(instr);
    try testing.expect(std.mem.indexOf(u8, instr, SENTINEL) != null);

    cleanup(io, tmp);
}

test "--only claude-desktop writes AGENTS.md, CLAUDE.md import, claude skill" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "claude-desktop");
    defer opts.only.deinit(gpa);
    const counts = try runDefaults(io, gpa, tmp, opts);
    try testing.expectEqual(@as(usize, 4), counts.added);
    try testing.expect(try exists(io, gpa, tmp, "AGENTS.md"));
    try testing.expect(try exists(io, gpa, tmp, ".agents/skills/caveman/SKILL.md"));
    const claude = (try readFileZ(io, gpa, tmp, "CLAUDE.md")).?;
    defer gpa.free(claude);
    try testing.expect(std.mem.startsWith(u8, claude, "@AGENTS.md"));
    try testing.expect(try exists(io, gpa, tmp, ".claude/skills/caveman/SKILL.md"));

    cleanup(io, tmp);
}

test "CLAUDE.md import idempotent when @AGENTS.md present" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const cl = try std.fs.path.join(gpa, &.{ tmp, "CLAUDE.md" });
    defer gpa.free(cl);
    try common.writeSmall(io, cl, "@AGENTS.md\n\n## Claude-only\nKeep this.\n");

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "claude-code");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    // claude-code maps to agents + claude-import + claude-skill; find the import one.
    var saw_skip = false;
    for (selected.items) |agent| {
        const r = try processAgent(io, gpa, agent, &opts);
        if (agent.mode == .import_agents) {
            try testing.expectEqualStrings("skipped-already-installed", r.status);
            saw_skip = true;
        }
    }
    try testing.expect(saw_skip);
    // Exactly one @AGENTS.md still.
    const claude = (try readFileZ(io, gpa, tmp, "CLAUDE.md")).?;
    defer gpa.free(claude);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, claude, "@AGENTS.md"));

    cleanup(io, tmp);
}

test "CLAUDE.md import appends when legacy caveman text lacks @AGENTS.md" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const cl = try std.fs.path.join(gpa, &.{ tmp, "CLAUDE.md" });
    defer gpa.free(cl);
    try common.writeSmall(io, cl, "## Legacy\nRespond terse like smart caveman. Keep this.\n");

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "claude-code");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    var saw_append = false;
    for (selected.items) |agent| {
        const r = try processAgent(io, gpa, agent, &opts);
        if (agent.mode == .import_agents) {
            try testing.expectEqualStrings("appended", r.status);
            saw_append = true;
        }
    }
    try testing.expect(saw_append);
    const claude = (try readFileZ(io, gpa, tmp, "CLAUDE.md")).?;
    defer gpa.free(claude);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, claude, "@AGENTS.md"));
    try testing.expect(std.mem.indexOf(u8, claude, "Respond terse like smart caveman") != null);

    cleanup(io, tmp);
}

test "safety: refuses to write through existing symlink target" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const outside = try std.fmt.allocPrint(gpa, "{s}-outside.md", .{tmp});
    defer gpa.free(outside);
    try common.writeSmall(io, outside, "outside stays unchanged\n");

    const agents_link = try std.fs.path.join(gpa, &.{ tmp, "AGENTS.md" });
    defer gpa.free(agents_link);
    std.Io.Dir.cwd().symLink(io, outside, agents_link, .{}) catch {
        // symlink unsupported on this fs — skip gracefully.
        cleanup(io, tmp);
        std.Io.Dir.cwd().deleteFile(io, outside) catch {};
        return;
    };

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "antigravity-app");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    var saw_symlink_skip = false;
    for (selected.items) |agent| {
        const r = try processAgent(io, gpa, agent, &opts);
        if (agent.mode == .append and agent.file != null and std.mem.eql(u8, agent.file.?, "AGENTS.md")) {
            try testing.expectEqualStrings("skipped-symlink", r.status);
            saw_symlink_skip = true;
        }
    }
    try testing.expect(saw_symlink_skip);
    const od = try common.readSmall(io, gpa, outside);
    defer gpa.free(od);
    try testing.expectEqualStrings("outside stays unchanged\n", od);

    std.Io.Dir.cwd().deleteFile(io, agents_link) catch {};
    std.Io.Dir.cwd().deleteFile(io, outside) catch {};
    cleanup(io, tmp);
}

test "safety: refuses to write through symlinked parent directory" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const outside_dir = try std.fmt.allocPrint(gpa, "{s}-outdir", .{tmp});
    defer gpa.free(outside_dir);
    mkdirP(io, outside_dir);

    const codex_link = try std.fs.path.join(gpa, &.{ tmp, ".codex" });
    defer gpa.free(codex_link);
    std.Io.Dir.cwd().symLink(io, outside_dir, codex_link, .{}) catch {
        cleanup(io, tmp);
        return;
    };

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "codex-app");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    var saw_unsafe = false;
    for (selected.items) |agent| {
        const r = try processAgent(io, gpa, agent, &opts);
        if (agent.mode == .skill and std.mem.eql(u8, agent.id, "codex-skill")) {
            try testing.expectEqualStrings("skipped-unsafe-parent", r.status);
            saw_unsafe = true;
        }
    }
    try testing.expect(saw_unsafe);
    // AGENTS.md should still be written.
    try testing.expect(try exists(io, gpa, tmp, "AGENTS.md"));
    // Skill should NOT be written through the parent symlink.
    const through = try std.fs.path.join(gpa, &.{ outside_dir, "skills", "caveman", "SKILL.md" });
    defer gpa.free(through);
    try testing.expect(common.classify(io, through) == .missing);

    std.Io.Dir.cwd().deleteFile(io, codex_link) catch {};
    cleanup(io, tmp);
}

test "detects sentinel and skips already-installed files" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const tmp = try tmpRepo(io, gpa);
    defer gpa.free(tmp);

    const dir = try std.fs.path.join(gpa, &.{ tmp, ".clinerules" });
    defer gpa.free(dir);
    mkdirP(io, dir);
    const file = try std.fs.path.join(gpa, &.{ dir, "caveman.md" });
    defer gpa.free(file);
    try common.writeSmall(io, file, "# Existing\n\nRespond terse like smart caveman. Hello.\n");

    var opts: Opts = .{ .target = tmp };
    try opts.only.append(gpa, "cline");
    defer opts.only.deinit(gpa);
    var selected: std.ArrayList(Agent) = .empty;
    defer selected.deinit(gpa);
    try resolveAgents(gpa, opts.only.items, &selected);
    const r = try processAgent(io, gpa, selected.items[0], &opts);
    try testing.expectEqualStrings("skipped-already-installed", r.status);

    cleanup(io, tmp);
}

test "unknown agent rejected" {
    const gpa = testing.allocator;
    var out: std.ArrayList(Agent) = .empty;
    defer out.deinit(gpa);
    var only: std.ArrayList([]const u8) = .empty;
    defer only.deinit(gpa);
    try only.append(gpa, "not-a-real-agent");
    try testing.expectError(error.UnknownAgent, resolveAgents(gpa, only.items, &out));
}

test "hasAgentsImport line anchors" {
    try testing.expect(hasAgentsImport("@AGENTS.md\n\nfoo"));
    try testing.expect(hasAgentsImport("foo\n@AGENTS.md\n"));
    try testing.expect(hasAgentsImport("@AGENTS.md"));
    try testing.expect(!hasAgentsImport("x@AGENTS.md\n"));
    try testing.expect(!hasAgentsImport("@AGENTS.mdx\n"));
}

// Recursively remove a temp dir (best-effort). STDLIB FIRST: std.Io.Dir.deleteTree
// is the recursive-removal primitive — for a path that is a file, symlink, or
// directory it removes it, recursing into directory entries first. It does NOT
// follow a symlink into its target (it unlinks the link itself), matching the old
// classify-then-unlink behavior where symlinks fell into the `else` (unlink-in-place)
// branch. Best-effort: every error is swallowed (the temp dir is throwaway).
fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}
