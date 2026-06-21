//! caveman-install — unified cross-platform installer, Zig 0.16 (libc C-ABI).
//!
//! Port of bin/install.js (2279 LOC). One binary detects the installed agents
//! and installs caveman for each. Single source of truth, like the JS.
//!
//! Written against the stable libc C ABI (std.c + a couple of extern decls)
//! rather than std.Io — every other binary in this tree links libc and stays on
//! the same interface (common.zig). Subprocess spawns use the fork+execvp +
//! pipe/dup2 pattern proven in shrink.zig (std.process.Child needs a std.Io
//! parameter in this 0.16-dev build). See irreducibleShims in the task report.
//!
//! REUSES the stage-1 lib modules instead of reimplementing:
//!   - settings.zig       readSettings / validate / addCommandHook /
//!                        removeCavemanHooks / prune / rewrite
//!   - openclaw.zig       OpenClaw workspace install/uninstall
//!   - nullclaw.zig       NullClaw workspace install/uninstall
//!   - opencode_agent.zig stripOpencodeAgentTools (subagent frontmatter)
//!   - common.zig         safeWriteFlag, classify, file IO, env helpers
//!
//! DEFERRED to R4c (documented): the network-dependent installHooks download +
//! SHA-256 verify path (curl/https + checksums.sha256). The local-clone copy
//! path of installHooks IS ported. External-CLI install side effects
//! (claude/gemini/npx) execute via the fork+execvp spawn helper; their dry-run
//! "would run:" lines are byte-exact with the JS.

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

const common = @import("common.zig");
const settings = @import("settings.zig");
const openclaw = @import("openclaw.zig");
const nullclaw = @import("nullclaw.zig");
const opencode_agent = @import("opencode_agent.zig");

// ── libc decls not surfaced under these names in std.c for this dev build ─────
extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *c.Stat) c_int;
// `stat` isn't surfaced under this name in std.c for this dev build (matches
// settings.zig's extern stat decl).
extern "c" fn stat(path: [*:0]const u8, buf: *c.Stat) c_int;

pub const REPO = "JuliusBrussee/caveman";
pub const MCP_SHRINK_PKG = "caveman-shrink";

// Hook files copied by installHooks (local-clone path). Mirrors HOOK_FILES.
const HOOK_FILES = [_][]const u8{
    "package.json",
    "caveman-config.js",
    "caveman-activate.js",
    "caveman-mode-tracker.js",
    "caveman-stats.js",
    "caveman-statusline.sh",
    "caveman-statusline.ps1",
};

// ── Aliases & init-target sets (mirror PROVIDER_ALIASES / INIT_*) ─────────────
const Alias = struct { from: []const u8, to: []const u8 };
const PROVIDER_ALIASES = [_]Alias{
    .{ .from = "aider", .to = "aider-desk" },
    .{ .from = "claude-code", .to = "claude" },
    .{ .from = "codex-app", .to = "codex" },
    .{ .from = "codex-cli", .to = "codex" },
    .{ .from = "antigravity-app", .to = "antigravity" },
    .{ .from = "antigravity-cli", .to = "antigravity" },
    .{ .from = "warp-preview", .to = "warp" },
    .{ .from = "warppreview", .to = "warp" },
};

const INIT_ONLY_AGENTS = [_][]const u8{
    "claude-desktop", "zeroclaw", "goclaw",  "hermes",  "perplexity",
    "pi",             "pz",       "walcode", "walkode", "claw",
};

const INIT_TARGET_ALIASES = [_][]const u8{
    "agents",       "antigravity", "antigravity-app", "antigravity-cli",
    "claude",       "claude-code", "claude-desktop",  "cline",
    "codex",        "codex-app",   "codex-cli",       "copilot",
    "cursor",       "goclaw",      "hermes",          "nullclaw",
    "opencode",     "openclaw",    "perplexity",      "pi",
    "pz",           "walcode",     "walkode",         "warp",
    "warp-preview", "warppreview", "windsurf",        "zeroclaw",
};

fn inList(list: []const []const u8, v: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, v)) return true;
    return false;
}

fn isInitTarget(id: []const u8) bool {
    return inList(&INIT_TARGET_ALIASES, id) or inList(&INIT_ONLY_AGENTS, id);
}

// ── Provider matrix (mirror PROVIDERS exactly, in order) ──────────────────────
const Provider = struct {
    id: []const u8,
    label: []const u8,
    mech: []const u8,
    detect: []const u8,
    profile: ?[]const u8 = null,
    soft: bool = false,
};

const PROVIDERS = [_]Provider{
    .{ .id = "claude", .label = "Claude Code", .mech = "claude plugin install", .detect = "command:claude" },
    .{ .id = "gemini", .label = "Gemini CLI", .mech = "gemini extensions install", .detect = "command:gemini" },
    .{ .id = "opencode", .label = "opencode", .mech = "native opencode plugin", .detect = "command:opencode" },
    .{ .id = "openclaw", .label = "OpenClaw", .mech = "workspace skill + SOUL.md", .detect = "command:openclaw||dir:$HOME/.openclaw/workspace" },
    .{ .id = "nullclaw", .label = "NullClaw", .mech = "workspace skill", .detect = "command:nullclaw" },
    .{ .id = "codex", .label = "Codex CLI", .mech = "npx skills add (codex)", .detect = "command:codex", .profile = "codex" },

    .{ .id = "cursor", .label = "Cursor", .mech = "npx skills add (cursor)", .detect = "command:cursor||macapp:Cursor", .profile = "cursor" },
    .{ .id = "windsurf", .label = "Windsurf", .mech = "npx skills add (windsurf)", .detect = "command:windsurf||macapp:Windsurf", .profile = "windsurf" },
    .{ .id = "cline", .label = "Cline", .mech = "npx skills add (cline)", .detect = "vscode-ext:cline", .profile = "cline" },
    .{ .id = "continue", .label = "Continue", .mech = "npx skills add (continue)", .detect = "vscode-ext:continue.continue||vscode-ext:continue", .profile = "continue" },
    .{ .id = "kilo", .label = "Kilo Code", .mech = "npx skills add (kilo)", .detect = "vscode-ext:kilocode", .profile = "kilo" },
    .{ .id = "roo", .label = "Roo Code", .mech = "npx skills add (roo)", .detect = "vscode-ext:roo||vscode-ext:rooveterinaryinc.roo-cline||cursor-ext:roo", .profile = "roo" },
    .{ .id = "augment", .label = "Augment Code", .mech = "npx skills add (augment)", .detect = "vscode-ext:augment||jetbrains-plugin:augment", .profile = "augment" },

    .{ .id = "copilot", .label = "GitHub Copilot", .mech = "npx skills add (github-copilot)", .detect = "vscode-ext:github.copilot||vscode-ext:github.copilot-chat||cursor-ext:github.copilot", .profile = "github-copilot" },

    .{ .id = "aider-desk", .label = "Aider Desk", .mech = "npx skills add (aider-desk)", .detect = "command:aider", .profile = "aider-desk" },
    .{ .id = "amp", .label = "Sourcegraph Amp", .mech = "npx skills add (amp)", .detect = "command:amp", .profile = "amp" },
    .{ .id = "bob", .label = "IBM Bob", .mech = "npx skills add (bob)", .detect = "command:bob", .profile = "bob" },
    .{ .id = "crush", .label = "Crush", .mech = "npx skills add (crush)", .detect = "command:crush", .profile = "crush" },
    .{ .id = "devin", .label = "Devin (terminal)", .mech = "npx skills add (devin)", .detect = "command:devin", .profile = "devin" },
    .{ .id = "droid", .label = "Droid (Factory)", .mech = "npx skills add (droid)", .detect = "command:droid", .profile = "droid" },
    .{ .id = "forgecode", .label = "ForgeCode", .mech = "npx skills add (forgecode)", .detect = "command:forge", .profile = "forgecode" },
    .{ .id = "goose", .label = "Block Goose", .mech = "npx skills add (goose)", .detect = "command:goose", .profile = "goose" },
    .{ .id = "iflow", .label = "iFlow CLI", .mech = "npx skills add (iflow-cli)", .detect = "command:iflow", .profile = "iflow-cli" },
    .{ .id = "kiro", .label = "Kiro CLI", .mech = "npx skills add (kiro-cli)", .detect = "command:kiro", .profile = "kiro-cli" },
    .{ .id = "mistral", .label = "Mistral Vibe", .mech = "npx skills add (mistral-vibe)", .detect = "command:mistral", .profile = "mistral-vibe" },
    .{ .id = "openhands", .label = "OpenHands", .mech = "npx skills add (openhands)", .detect = "command:openhands", .profile = "openhands" },
    .{ .id = "qwen", .label = "Qwen Code", .mech = "npx skills add (qwen-code)", .detect = "command:qwen", .profile = "qwen-code" },
    .{ .id = "rovodev", .label = "Atlassian Rovo Dev", .mech = "npx skills add (rovodev)", .detect = "command:rovodev", .profile = "rovodev" },
    .{ .id = "tabnine", .label = "Tabnine CLI", .mech = "npx skills add (tabnine-cli)", .detect = "command:tabnine", .profile = "tabnine-cli" },
    .{ .id = "trae", .label = "Trae", .mech = "npx skills add (trae)", .detect = "command:trae", .profile = "trae" },
    .{ .id = "warp", .label = "Warp", .mech = "npx skills add (warp)", .detect = "command:warp", .profile = "warp" },
    .{ .id = "replit", .label = "Replit Agent", .mech = "npx skills add (replit)", .detect = "command:replit", .profile = "replit" },

    .{ .id = "junie", .label = "JetBrains Junie", .mech = "npx skills add (junie)", .detect = "jetbrains-plugin:junie", .profile = "junie", .soft = true },
    .{ .id = "qoder", .label = "Qoder", .mech = "npx skills add (qoder)", .detect = "dir:$HOME/.qoder", .profile = "qoder", .soft = true },
    .{ .id = "antigravity", .label = "Google Antigravity", .mech = "npx skills add (antigravity)", .detect = "dir:$HOME/.gemini/antigravity", .profile = "antigravity", .soft = true },
};

fn providerById(id: []const u8) ?Provider {
    for (PROVIDERS) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

// ── opencode manifest (mirror OPENCODE_* constants) ───────────────────────────
const OPENCODE_SKILL_DIRS = [_][]const u8{
    "caveman",       "caveman-commit",   "caveman-review", "caveman-help",
    "caveman-stats", "caveman-compress", "cavecrew",
};
const OPENCODE_AGENT_FILES = [_][]const u8{
    "cavecrew-investigator.md", "cavecrew-builder.md", "cavecrew-reviewer.md",
};
const OPENCODE_COMMAND_FILES = [_][]const u8{
    "caveman.md",          "caveman-commit.md", "caveman-review.md",
    "caveman-compress.md", "caveman-stats.md",  "caveman-help.md",
};
const OPENCODE_PLUGIN_REL = "./plugins/caveman/plugin.js";
const OPENCODE_AGENTS_MD_SENTINEL = "Respond terse like smart caveman";
const OPENCODE_AGENTS_MD_BEGIN = "<!-- caveman-begin -->";
const OPENCODE_AGENTS_MD_END = "<!-- caveman-end -->";

// ── Options ───────────────────────────────────────────────────────────────────
const WithHooks = enum { auto, on, off };

const Opts = struct {
    dry_run: bool = false,
    force: bool = false,
    skip_skills: bool = false,
    with_hooks: WithHooks = .auto,
    with_init: bool = false,
    with_mcp_shrink: bool = false,
    mcp_shrink_cmd: ?[]const u8 = null, // joined upstream tokens (display)
    all: bool = false,
    minimal: bool = false,
    list_only: bool = false,
    no_color: bool = false,
    only: std.ArrayList([]const u8) = .empty,
    init_only: std.ArrayList([]const u8) = .empty,
    uninstall: bool = false,
    non_interactive: bool = false,
    config_dir: ?[]const u8 = null,
    help: bool = false,
};

// ── stdout / stderr ───────────────────────────────────────────────────────────
fn out(s: []const u8) void {
    common.writeStdout(s);
}
fn err(s: []const u8) void {
    common.writeStderr(s);
}

fn die(msg: []const u8) noreturn {
    err(msg);
    err("\n");
    std.process.exit(2);
}

// ── Argv normalization (mirror normalizeAgentId / resolveProviderOnlyId) ──────
fn normalizeAgentId(gpa: std.mem.Allocator, id: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, id, " \t\r\n");
    const buf = gpa.alloc(u8, trimmed.len) catch return trimmed;
    for (trimmed, 0..) |ch, i| {
        const lc = std.ascii.toLower(ch);
        buf[i] = if (lc == '_') '-' else lc;
    }
    return buf;
}

fn resolveProviderOnlyId(id: []const u8) []const u8 {
    for (PROVIDER_ALIASES) |a| {
        if (std.mem.eql(u8, a.from, id)) return a.to;
    }
    return id;
}

fn expandHome(gpa: std.mem.Allocator, p: []const u8) []const u8 {
    const home = common.getenv("HOME") orelse return gpa.dupe(u8, p) catch p;
    if (std.mem.startsWith(u8, p, "$HOME")) {
        return std.mem.concat(gpa, u8, &.{ home, p["$HOME".len..] }) catch p;
    }
    if (std.mem.startsWith(u8, p, "~")) {
        return std.mem.concat(gpa, u8, &.{ home, p["~".len..] }) catch p;
    }
    return gpa.dupe(u8, p) catch p;
}

// ── parseArgs ─────────────────────────────────────────────────────────────────
const ParseError = error{Die};

fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) Opts {
    var opts: Opts = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (std.mem.startsWith(u8, a, "--with-mcp-shrink=")) {
            const raw = a["--with-mcp-shrink=".len..];
            const joined = joinTokens(gpa, std.mem.trim(u8, raw, " \t"));
            if (joined.len == 0) {
                die("error: --with-mcp-shrink requires an upstream command\n" ++
                    "  example: --with-mcp-shrink=\"npx @modelcontextprotocol/server-filesystem /path\"");
            }
            opts.with_mcp_shrink = true;
            opts.mcp_shrink_cmd = joined;
            continue;
        }

        if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--skip-skills")) {
            opts.skip_skills = true;
        } else if (std.mem.eql(u8, a, "--with-hooks")) {
            opts.with_hooks = .on;
        } else if (std.mem.eql(u8, a, "--no-hooks")) {
            opts.with_hooks = .off;
        } else if (std.mem.eql(u8, a, "--with-init")) {
            opts.with_init = true;
        } else if (std.mem.eql(u8, a, "--with-mcp-shrink")) {
            const v: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
            if (v != null and !std.mem.startsWith(u8, v.?, "--")) {
                i += 1;
                const joined = joinTokens(gpa, std.mem.trim(u8, v.?, " \t"));
                if (joined.len == 0) {
                    die("error: --with-mcp-shrink requires an upstream command\n" ++
                        "  example: --with-mcp-shrink \"npx @modelcontextprotocol/server-filesystem /path\"");
                }
                opts.with_mcp_shrink = true;
                opts.mcp_shrink_cmd = joined;
            } else {
                die("error: --with-mcp-shrink requires an upstream command — caveman-shrink\n" ++
                    "  is a proxy and exits immediately without one. Pass the upstream:\n" ++
                    "  --with-mcp-shrink=\"npx @modelcontextprotocol/server-filesystem /path\"");
            }
        } else if (std.mem.eql(u8, a, "--no-mcp-shrink")) {
            opts.with_mcp_shrink = false;
            opts.mcp_shrink_cmd = null;
        } else if (std.mem.eql(u8, a, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, a, "--minimal")) {
            opts.minimal = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            opts.list_only = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, a, "--uninstall") or std.mem.eql(u8, a, "-u")) {
            opts.uninstall = true;
        } else if (std.mem.eql(u8, a, "--non-interactive")) {
            opts.non_interactive = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, a, "--")) {
            // POSIX end-of-options marker — accept and ignore.
        } else if (std.mem.eql(u8, a, "--only")) {
            i += 1;
            if (i >= argv.len) die("error: --only requires an argument");
            const id = normalizeAgentId(gpa, argv[i]);
            opts.only.append(gpa, resolveProviderOnlyId(id)) catch {};
            if (isInitTarget(id)) opts.init_only.append(gpa, id) catch {};
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            i += 1;
            if (i >= argv.len or std.mem.startsWith(u8, argv[i], "--")) {
                die("error: --config-dir requires a path");
            }
            opts.config_dir = expandHome(gpa, argv[i]);
        } else {
            var msg: std.ArrayList(u8) = .empty;
            msg.appendSlice(gpa, "error: unknown flag: ") catch {};
            msg.appendSlice(gpa, a) catch {};
            msg.appendSlice(gpa, "\nrun 'caveman --help' for usage") catch {};
            die(msg.items);
        }
    }

    if (opts.all and opts.minimal) {
        die("error: --all and --minimal are mutually exclusive");
    }
    if (opts.all) opts.with_init = true;
    if (opts.minimal) {
        opts.with_hooks = .off;
        opts.with_init = false;
        opts.with_mcp_shrink = false;
        opts.mcp_shrink_cmd = null;
    }

    // Validate --only ids against the provider matrix / init targets.
    for (opts.only.items) |id| {
        const is_provider = providerById(id) != null;
        const is_init = isInitTarget(id);
        if (!is_provider and !is_init) {
            var msg: std.ArrayList(u8) = .empty;
            msg.appendSlice(gpa, "error: unknown agent: ") catch {};
            msg.appendSlice(gpa, id) catch {};
            msg.appendSlice(gpa, "\n  see 'caveman --list' for valid ids") catch {};
            die(msg.items);
        }
        if (!is_provider and is_init and !opts.with_init) {
            var msg: std.ArrayList(u8) = .empty;
            msg.appendSlice(gpa, "error: ") catch {};
            msg.appendSlice(gpa, id) catch {};
            msg.appendSlice(gpa, " is a repo-local init target; pass --with-init or --all") catch {};
            die(msg.items);
        }
    }

    return opts;
}

/// Whitespace-tokenize then re-join with single spaces (mirrors the JS
/// `raw.trim().split(/\s+/).filter(Boolean)` then later `.join(" ")`).
fn joinTokens(gpa: std.mem.Allocator, raw: []const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    var first = true;
    while (it.next()) |tok| {
        if (!first) list.append(gpa, ' ') catch {};
        first = false;
        list.appendSlice(gpa, tok) catch {};
    }
    return list.toOwnedSlice(gpa) catch "";
}

// ── Detection ─────────────────────────────────────────────────────────────────
fn hasCmd(gpa: std.mem.Allocator, cmd: []const u8) bool {
    // `command -v <cmd>` via /bin/sh, stdio discarded. fork+execvp, waitpid.
    const argv = [_][:0]const u8{
        gpa.dupeZ(u8, "/bin/sh") catch return false,
        gpa.dupeZ(u8, "-c") catch return false,
        std.fmt.allocPrintSentinel(gpa, "command -v {s}", .{shellEscape(gpa, cmd)}, 0) catch return false,
    };
    const status = spawnWaitQuiet(gpa, &argv) orelse return false;
    return status == 0;
}

fn shellEscape(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    list.append(gpa, '\'') catch return s;
    for (s) |ch| {
        if (ch == '\'') {
            list.appendSlice(gpa, "'\\''") catch {};
        } else {
            list.append(gpa, ch) catch {};
        }
    }
    list.append(gpa, '\'') catch {};
    return list.toOwnedSlice(gpa) catch s;
}

fn pathExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, path) catch return false;
    var st: c.Stat = undefined;
    return stat(z, &st) == 0;
}

fn isDirReal(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, path) catch return false;
    var st: c.Stat = undefined;
    if (stat(z, &st) != 0) return false;
    return (st.mode & c.S.IFMT) == c.S.IFDIR;
}

fn isFileReal(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, path) catch return false;
    var st: c.Stat = undefined;
    if (stat(z, &st) != 0) return false;
    return (st.mode & c.S.IFMT) == c.S.IFREG;
}

fn macAppPresent(gpa: std.mem.Allocator, name: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const home = common.getenv("HOME") orelse return false;
    const slash_apps = std.fmt.allocPrint(gpa, "/Applications/{s}.app", .{name}) catch return false;
    if (pathExists(slash_apps)) return true;
    const user_apps = std.fmt.allocPrint(gpa, "{s}/Applications/{s}.app", .{ home, name }) catch return false;
    return pathExists(user_apps);
}

/// Case-insensitive substring (needle assumed lowercase by caller convention).
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn dirHasEntryMatching(gpa: std.mem.Allocator, dir: []const u8, needle: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, dir) catch return false;
    const dp = c.opendir(z) orelse return false;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |ent| {
        const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
        if (containsCI(nm, needle)) return true;
    }
    _ = gpa;
    return false;
}

fn vscodeExtPresent(gpa: std.mem.Allocator, needle: []const u8) bool {
    const home = common.getenv("HOME") orelse return false;
    const roots = [_][]const u8{
        ".vscode/extensions", ".vscode-server/extensions",
        ".cursor/extensions", ".windsurf/extensions",
    };
    for (roots) |rel| {
        const root = std.fs.path.join(gpa, &.{ home, rel }) catch continue;
        if (!isDirReal(root)) continue;
        if (dirHasEntryMatching(gpa, root, needle)) return true;
    }
    return false;
}

fn cursorExtPresent(gpa: std.mem.Allocator, needle: []const u8) bool {
    const home = common.getenv("HOME") orelse return false;
    const dir = std.fs.path.join(gpa, &.{ home, ".cursor/extensions" }) catch return false;
    if (!isDirReal(dir)) return false;
    return dirHasEntryMatching(gpa, dir, needle);
}

/// Recursive needle-in-basename walk under JetBrains config roots (depth 4).
fn jetbrainsWalk(gpa: std.mem.Allocator, root: []const u8, needle: []const u8, depth: i32) bool {
    if (depth < 0) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, root) catch return false;
    const dp = c.opendir(z) orelse return false;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |ent| {
        const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
        const child = std.fs.path.join(gpa, &.{ root, nm }) catch continue;
        if (!isDirReal(child)) continue;
        if (containsCI(nm, needle)) return true;
        if (jetbrainsWalk(gpa, child, needle, depth - 1)) return true;
    }
    return false;
}

fn jetbrainsPluginPresent(gpa: std.mem.Allocator, needle: []const u8) bool {
    const home = common.getenv("HOME") orelse return false;
    const roots = [_][]const u8{
        "Library/Application Support/JetBrains", ".config/JetBrains",
    };
    for (roots) |rel| {
        const root = std.fs.path.join(gpa, &.{ home, rel }) catch continue;
        if (!isDirReal(root)) continue;
        if (jetbrainsWalk(gpa, root, needle, 4)) return true;
    }
    return false;
}

fn jetbrainsPresent(gpa: std.mem.Allocator) bool {
    const home = common.getenv("HOME") orelse return false;
    const a = std.fs.path.join(gpa, &.{ home, "Library/Application Support/JetBrains" }) catch return false;
    if (pathExists(a)) return true;
    const b = std.fs.path.join(gpa, &.{ home, ".config/JetBrains" }) catch return false;
    return pathExists(b);
}

/// Evaluate a detect spec ("kind:val||kind:val||..."). Mirrors detectMatch.
fn detectMatch(gpa: std.mem.Allocator, spec: []const u8) bool {
    if (spec.len == 0) return false;
    var it = std.mem.splitSequence(u8, spec, "||");
    while (it.next()) |clause_raw| {
        const clause = std.mem.trim(u8, clause_raw, " \t");
        if (clause.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, clause, ':');
        const kind = if (colon) |ci| clause[0..ci] else clause;
        const val_raw = if (colon) |ci| clause[ci + 1 ..] else "";
        const val = expandHome(gpa, val_raw);
        var ok = false;
        if (std.mem.eql(u8, kind, "command")) {
            ok = hasCmd(gpa, val);
        } else if (std.mem.eql(u8, kind, "dir")) {
            ok = isDirReal(val);
        } else if (std.mem.eql(u8, kind, "file")) {
            ok = isFileReal(val);
        } else if (std.mem.eql(u8, kind, "macapp")) {
            ok = macAppPresent(gpa, val);
        } else if (std.mem.eql(u8, kind, "vscode-ext")) {
            ok = vscodeExtPresent(gpa, val);
        } else if (std.mem.eql(u8, kind, "cursor-ext")) {
            ok = cursorExtPresent(gpa, val);
        } else if (std.mem.eql(u8, kind, "jetbrains-config")) {
            ok = jetbrainsPresent(gpa);
        } else if (std.mem.eql(u8, kind, "jetbrains-plugin")) {
            ok = jetbrainsPluginPresent(gpa, val);
        }
        if (ok) return true;
    }
    return false;
}

// ── Subprocess spawn (fork+execvp, mirror shrink.zig pattern) ─────────────────
/// Spawn argv (NUL-terminated args), inherit stdio, wait, return exit status.
fn spawnWaitInherit(gpa: std.mem.Allocator, argv: []const [:0]const u8) ?u8 {
    return spawnWait(gpa, argv, false);
}

/// Same, but discard child stdout/stderr (for detection / capture probes).
fn spawnWaitQuiet(gpa: std.mem.Allocator, argv: []const [:0]const u8) ?u8 {
    return spawnWait(gpa, argv, true);
}

fn spawnWait(gpa: std.mem.Allocator, argv: []const [:0]const u8, quiet: bool) ?u8 {
    if (argv.len == 0) return null;
    const cargv = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch return null;
    defer gpa.free(cargv);
    for (argv, 0..) |a, i| cargv[i] = a.ptr;

    const pid = fork();
    if (pid < 0) return null;
    if (pid == 0) {
        if (quiet) {
            const devnull = c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
            if (devnull >= 0) {
                _ = c.dup2(devnull, 1);
                _ = c.dup2(devnull, 2);
            }
        }
        _ = execvp(argv[0].ptr, cargv.ptr);
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (c.W.IFEXITED(ustatus)) return @intCast(c.W.EXITSTATUS(ustatus) & 0xff);
    return 1;
}

/// Capture a child's stdout into an owned buffer (mirrors captureSpawn). Returns
/// {status, stdout}. Used by claude/gemini idempotency probes.
const Capture = struct { status: u8, stdout: []u8 };

fn captureSpawn(gpa: std.mem.Allocator, argv: []const [:0]const u8) ?Capture {
    if (argv.len == 0) return null;
    var out_fds: [2]c.fd_t = undefined;
    if (c.pipe(&out_fds) != 0) return null;

    const cargv = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        return null;
    };
    defer gpa.free(cargv);
    for (argv, 0..) |a, i| cargv[i] = a.ptr;

    const pid = fork();
    if (pid < 0) {
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = c.dup2(out_fds[1], 1);
        const devnull = c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
        if (devnull >= 0) _ = c.dup2(devnull, 2);
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        _ = execvp(argv[0].ptr, cargv.ptr);
        c._exit(127);
    }
    _ = close(out_fds[1]);
    var buf: std.ArrayList(u8) = .empty;
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(out_fds[0], &rbuf, rbuf.len);
        if (n <= 0) break;
        buf.appendSlice(gpa, rbuf[0..@intCast(n)]) catch break;
    }
    _ = close(out_fds[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    const st: u8 = if (c.W.IFEXITED(ustatus)) @intCast(c.W.EXITSTATUS(ustatus) & 0xff) else 1;
    return .{ .status = st, .stdout = buf.toOwnedSlice(gpa) catch "" };
}

/// runSpawn analogue: prints "would run:" (dry) or "$ cmd args" then spawns.
/// `args` are plain slices; we dupeZ them for execvp. Returns 0 on dry-run.
fn runSpawn(gpa: std.mem.Allocator, args: []const []const u8, dry: bool) u8 {
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        line.appendSlice(gpa, if (dry) "  would run: " else "  $ ") catch {};
        for (args, 0..) |a, i| {
            if (i != 0) line.append(gpa, ' ') catch {};
            line.appendSlice(gpa, a) catch {};
        }
        line.append(gpa, '\n') catch {};
        out(line.items);
    }
    if (dry) return 0;

    var zargs: std.ArrayList([:0]const u8) = .empty;
    defer zargs.deinit(gpa);
    for (args) |a| zargs.append(gpa, gpa.dupeZ(u8, a) catch return 1) catch return 1;
    return spawnWaitInherit(gpa, zargs.items) orelse 1;
}

// ── settings.json read / write (mirror SETTINGS.readSettings/writeSettings) ───
// The whole installer runs on one top-level arena (main()'s c_allocator-backed
// ArenaAllocator); settings parsing allocates into that same arena and is never
// individually freed. SettingsDoc therefore just carries the parsed value plus
// the program allocator (used for in-place ObjectMap/Array mutation). It must
// NOT spin up a nested ArenaAllocator: a std.json.ObjectMap captures the address
// of its allocator state, so copying a by-value ArenaAllocator out of this
// function would dangle that pointer and crash on the first `.put`.
const SettingsDoc = struct {
    arena: std.mem.Allocator, // the program arena (NOT a nested ArenaAllocator)
    value: std.json.Value,

    fn deinit(self: *SettingsDoc) void {
        _ = self; // arena-backed; freed wholesale at program exit
    }
};

/// Read+parse a settings file. Returns null only when the file exists but is
/// unparseable (mirrors readSettings returning null). Missing file ⇒ empty {}.
fn readSettingsDoc(gpa: std.mem.Allocator, path: []const u8) ?SettingsDoc {
    const raw = if (common.existsNoFollow(path)) blk: {
        if (!common.isRegularFileNoSymlink(path)) return null;
        break :blk common.readFileAlloc(gpa, path, 16 * 1024 * 1024) orelse return null;
    } else "";
    const value = settings.parseSettings(gpa, raw) catch {
        // Existing-but-unparseable ⇒ JS null. Missing file already yields "".
        if (raw.len == 0) {
            return .{ .arena = gpa, .value = .{ .object = std.json.ObjectMap.init(gpa) } };
        }
        return null;
    };
    return .{ .arena = gpa, .value = value };
}

/// Atomic, symlink-safe settings.json write via common.safeWriteFlag.
fn writeSettingsFile(gpa: std.mem.Allocator, path: []const u8, value: std.json.Value) !void {
    const text = try settings.stringifySettings(gpa, value);
    defer gpa.free(text);
    try common.safeWriteFlag(gpa, path, text);
}

// ── Repo root resolution (mirror detectRepoRoot) ──────────────────────────────
/// Walk up from the cwd looking for a clone (src/hooks + agents + skills). The
/// JS keys off __filename (bin/install.js); we have no install path, so use the
/// cwd walk — same effect from inside a clone.
fn detectRepoRoot(gpa: std.mem.Allocator) ?[]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return null;
    var dir: []const u8 = gpa.dupe(u8, std.mem.sliceTo(cwd_z, 0)) catch return null;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const h = std.fs.path.join(gpa, &.{ dir, "src", "hooks" }) catch return null;
        const a = std.fs.path.join(gpa, &.{ dir, "agents" }) catch return null;
        const s = std.fs.path.join(gpa, &.{ dir, "skills" }) catch return null;
        if (isDirReal(h) and isDirReal(a) and isDirReal(s)) return dir;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = gpa.dupe(u8, parent) catch return null;
    }
    return null;
}

// ── Filesystem helpers ────────────────────────────────────────────────────────
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

fn copyFile(gpa: std.mem.Allocator, src: []const u8, dest: []const u8) bool {
    const data = common.readFileAlloc(gpa, src, 64 * 1024 * 1024) orelse return false;
    defer gpa.free(data);
    writeFile0644(dest, data) catch return false;
    return true;
}

fn writeFile0644(path: []const u8, content: []const u8) !void {
    if (common.isSymlink(path)) return error.SymlinkRefused;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (common.ancestorUnsafe(dir)) return error.ParentSymlinkRefused;
    if (!mkdirP(dir)) return error.ParentSymlinkRefused;

    const tmp = try std.fmt.allocPrint(std.heap.c_allocator, "{s}.tmp.{d}", .{ path, c.getpid() });
    defer std.heap.c_allocator.free(tmp);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tz = try common.toZ(&tbuf, tmp);
    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = c.open(tz, flags, @as(c.mode_t, 0o644));
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
    const pz = try common.toZ(&pbuf, path);
    if (c.rename(tz, pz) != 0) {
        _ = c.unlink(tz);
        return error.RenameFailed;
    }
}

fn copyDirRecursive(gpa: std.mem.Allocator, src: []const u8, dest: []const u8) void {
    if (!mkdirP(dest)) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = common.toZ(&buf, src) catch return;
    const dp = c.opendir(z) orelse return;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |ent| {
        const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
        const s = std.fs.path.join(gpa, &.{ src, nm }) catch continue;
        const d = std.fs.path.join(gpa, &.{ dest, nm }) catch continue;
        if (isDirReal(s)) {
            copyDirRecursive(gpa, s, d);
        } else if (isFileReal(s)) {
            _ = copyFile(gpa, s, d);
        }
    }
}

// ── Context ───────────────────────────────────────────────────────────────────
const Results = struct {
    installed: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList([2][]const u8) = .empty,
    failed: std.ArrayList([2][]const u8) = .empty,
    detected: usize = 0,
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    opts: *Opts,
    config_dir: []const u8,
    repo_root: ?[]const u8,
    results: *Results,
    color: Chalk,

    fn say(self: *Ctx, s: []const u8) void {
        self.color.write(out, self.color.orange, s);
        out("\n");
    }
    fn note(self: *Ctx, s: []const u8) void {
        self.color.write(out, self.color.dim, s);
        out("\n");
    }
    fn warn(self: *Ctx, s: []const u8) void {
        self.color.write(err, self.color.red, s);
        err("\n");
    }
    fn ok(self: *Ctx, s: []const u8) void {
        self.color.write(out, self.color.green, s);
        out("\n");
    }
};

// ── Color (mirror makeChalk; --no-color / non-TTY → plain) ────────────────────
const Chalk = struct {
    use_color: bool,
    orange: []const u8 = "38;5;172",
    dim: []const u8 = "2",
    red: []const u8 = "31",
    green: []const u8 = "32",
    yellow: []const u8 = "33",

    fn write(self: Chalk, sink: fn ([]const u8) void, code: []const u8, s: []const u8) void {
        if (self.use_color) {
            sink("\x1b[");
            sink(code);
            sink("m");
            sink(s);
            sink("\x1b[0m");
        } else {
            sink(s);
        }
    }
};

fn makeChalk(no_color: bool) Chalk {
    const tty = c.isatty(1) != 0;
    const no_color_env = common.getenv("NO_COLOR") != null;
    return .{ .use_color = !no_color and tty and !no_color_env };
}

// ── printList (byte-exact with JS) ────────────────────────────────────────────
fn pad(gpa: std.mem.Allocator, s: []const u8, n: usize) []const u8 {
    if (s.len >= n) return gpa.dupe(u8, s) catch s;
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(gpa, s) catch return s;
    var k: usize = s.len;
    while (k < n) : (k += 1) buf.append(gpa, ' ') catch {};
    return buf.toOwnedSlice(gpa) catch s;
}

fn printList(gpa: std.mem.Allocator, no_color: bool) void {
    const ch = makeChalk(no_color);
    ch.write(out, ch.orange, "🪨 caveman provider matrix");
    out("\n\n");

    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        line.appendSlice(gpa, "  ") catch {};
        line.appendSlice(gpa, pad(gpa, "ID", 13)) catch {};
        line.append(gpa, ' ') catch {};
        line.appendSlice(gpa, pad(gpa, "AGENT", 22)) catch {};
        line.appendSlice(gpa, " INSTALL MECHANISM\n") catch {};
        out(line.items);
    }
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        line.appendSlice(gpa, "  ") catch {};
        line.appendSlice(gpa, pad(gpa, "--", 13)) catch {};
        line.append(gpa, ' ') catch {};
        line.appendSlice(gpa, pad(gpa, "-----", 22)) catch {};
        line.appendSlice(gpa, " -----------------\n") catch {};
        out(line.items);
    }
    for (PROVIDERS) |p| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        line.appendSlice(gpa, "  ") catch {};
        line.appendSlice(gpa, pad(gpa, p.id, 13)) catch {};
        line.append(gpa, ' ') catch {};
        line.appendSlice(gpa, pad(gpa, p.label, 22)) catch {};
        line.append(gpa, ' ') catch {};
        line.appendSlice(gpa, p.mech) catch {};
        if (p.soft) line.appendSlice(gpa, " (soft)") catch {};
        line.append(gpa, '\n') catch {};
        out(line.items);
    }
    out("\n");
    ch.write(out, ch.dim, "  Aliases: aider→aider-desk, claude-code→claude, codex-app/codex-cli→codex,\n");
    ch.write(out, ch.dim, "           antigravity-app/antigravity-cli→antigravity, warpPreview/warp-preview→warp.\n");
    ch.write(out, ch.dim, "  Repo-only init ids: agents, claude-desktop, perplexity, zeroclaw, goclaw, hermes, pi, pz, walcode, walkode, claw.\n");
    ch.write(out, ch.dim, "  Defaults: --with-hooks ON, --with-init OFF, --with-mcp-shrink OFF.\n");
    ch.write(out, ch.dim, "  --all = hooks + init (mcp-shrink needs an upstream — opt in explicitly).\n");
    ch.write(out, ch.dim, "  --minimal turns hooks + init + mcp-shrink off.\n");
}

// ── printHelp (byte-exact with JS) ────────────────────────────────────────────
fn printHelp() void {
    out(
        \\caveman installer — detects your agents and installs caveman for each one.
        \\
        \\USAGE
        \\  npx -y github:JuliusBrussee/caveman -- [flags]
        \\  node bin/install.js [flags]
        \\  bash install.sh [flags]              # shim → npx
        \\  pwsh install.ps1 [flags]             # shim → npx
        \\
        \\FLAGS
        \\  --dry-run             Print what would run, do nothing.
        \\  --force               Re-run even if a target reports already installed.
        \\  --only <agent>        Install only for the named agent. Repeatable.
        \\                        See --list for valid ids and aliases. Repo-only
        \\                        harness ids require --with-init or --all.
        \\  --skip-skills         Don't run the npx-skills auto-detect fallback.
        \\  --all                 Turn on hooks + init. (mcp-shrink needs an upstream;
        \\                        pass --with-mcp-shrink="<cmd>" to add it.)
        \\  --minimal             Just the plugin/extension install.
        \\  --with-hooks          Claude Code: install SessionStart/UserPromptSubmit hooks
        \\                        + statusline badge. (Default ON.)
        \\  --no-hooks            Skip the hooks installer.
        \\  --with-init           Write per-repo IDE rule files into $PWD.
        \\  --with-mcp-shrink="<upstream cmd>"
        \\                        Claude Code (and opencode): register caveman-shrink MCP
        \\                        proxy wrapping the given upstream. Default OFF.
        \\                        caveman-shrink crashes without an upstream, so a value
        \\                        is required. The value is whitespace-tokenized.
        \\                        Example: --with-mcp-shrink="npx @modelcontextprotocol/server-filesystem /tmp"
        \\  --no-mcp-shrink       Skip MCP shrink. (Default.)
        \\  --uninstall, -u       Remove caveman from this machine.
        \\  --config-dir <path>   Claude Code config dir for hook files + settings.json.
        \\                        Default: $CLAUDE_CONFIG_DIR or ~/.claude. Does NOT
        \\                        scope `claude plugin install`, `gemini extensions
        \\                        install`, opencode (XDG_CONFIG_HOME), openclaw
        \\                        (OPENCLAW_WORKSPACE), or nullclaw
        \\                        (NULLCLAW_WORKSPACE/NULLCLAW_HOME) — those use their
        \\                        own paths.
        \\  --non-interactive     Never prompt; use defaults. (Auto when stdin is not a TTY.)
        \\  --list                Print provider matrix and exit.
        \\  --no-color            Disable ANSI colors.
        \\  -h, --help            Show this help.
        \\
        \\EXAMPLES
        \\  npx -y github:JuliusBrussee/caveman                        # default install
        \\  npx -y github:JuliusBrussee/caveman -- --all               # all the trimmings
        \\  npx -y github:JuliusBrussee/caveman -- --only claude --no-mcp-shrink
        \\  npx -y github:JuliusBrussee/caveman -- --with-init --only pi
        \\  npx -y github:JuliusBrussee/caveman -- --uninstall
        \\
        \\  Issues: https://github.com/JuliusBrussee/caveman/issues
        \\
    );
}

// ── opencode config dir resolution (mirror opencodeConfigDir) ─────────────────
fn opencodeConfigDir(gpa: std.mem.Allocator) []const u8 {
    if (common.getenv("OPENCODE_CONFIG_DIR")) |d| return gpa.dupe(u8, d) catch d;
    if (common.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(gpa, &.{ xdg, "opencode" }) catch xdg;
    }
    const home = common.getenv("HOME") orelse return "";
    return std.fs.path.join(gpa, &.{ home, ".config", "opencode" }) catch "";
}

// ── Result helpers ────────────────────────────────────────────────────────────
fn pushInstalled(ctx: *Ctx, id: []const u8) void {
    ctx.results.installed.append(ctx.gpa, id) catch {};
}
fn pushSkipped(ctx: *Ctx, id: []const u8, why: []const u8) void {
    ctx.results.skipped.append(ctx.gpa, .{ id, why }) catch {};
}
fn pushFailed(ctx: *Ctx, id: []const u8, why: []const u8) void {
    ctx.results.failed.append(ctx.gpa, .{ id, why }) catch {};
}

fn fmt(ctx: *Ctx, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ctx.gpa, f, args) catch "";
}

// ── installClaude ─────────────────────────────────────────────────────────────
fn installClaude(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say("→ Claude Code detected");

    var already = false;
    if (!opts.force) {
        const probe_args = [_][:0]const u8{
            gpa.dupeZ(u8, "claude") catch return,
            gpa.dupeZ(u8, "plugin") catch return,
            gpa.dupeZ(u8, "list") catch return,
        };
        if (captureSpawn(gpa, &probe_args)) |cap| {
            if (cap.status == 0 and containsCI(cap.stdout, "caveman")) already = true;
        }
    }

    var plugin_ok = false;
    if (already) {
        ctx.note("  caveman plugin already installed (use --force to reinstall)");
        pushSkipped(ctx, "claude", "plugin already installed");
        plugin_ok = true;
    } else {
        const r1 = runSpawn(gpa, &.{ "claude", "plugin", "marketplace", "add", REPO }, opts.dry_run);
        const r2 = runSpawn(gpa, &.{ "claude", "plugin", "install", "caveman@caveman" }, opts.dry_run);
        if (r1 == 0 and r2 == 0) {
            pushInstalled(ctx, "claude");
            plugin_ok = true;
        } else {
            pushFailed(ctx, "claude", "claude plugin install failed");
        }
    }

    // Self-heal orphaned managed hooks (prune).
    {
        const settings_path = std.fs.path.join(gpa, &.{ ctx.config_dir, "settings.json" }) catch ctx.config_dir;
        if (isFileReal(settings_path)) {
            if (readSettingsDoc(gpa, settings_path)) |doc_const| {
                var doc = doc_const;
                defer doc.deinit();
                const arena = doc.arena;
                const pruned = settings.pruneOrphanedManagedHooks(arena, &doc.value, ctx.config_dir) catch 0;
                if (pruned > 0) {
                    ctx.note(fmt(ctx, "  removed {d} orphaned caveman hook entr{s} from settings.json (target script missing)", .{ pruned, if (pruned == 1) "y" else "ies" }));
                    if (!opts.dry_run) {
                        settings.validateHookFields(arena, &doc.value) catch {};
                        writeSettingsFile(gpa, settings_path, doc.value) catch {};
                    }
                }
            }
        }
    }

    // Hook wiring decision matrix.
    var wire = false;
    if (opts.with_hooks == .off) {
        wire = false;
    } else if (opts.with_hooks == .on) {
        wire = true;
        if (plugin_ok) {
            ctx.warn("  --with-hooks wires hooks in settings.json alongside the plugin manifest.");
            ctx.warn("  Both will fire on every event. Pass --no-hooks to keep only the plugin path.");
        }
    } else {
        wire = !plugin_ok;
        if (!wire) {
            ctx.note("  hooks: plugin manifest handles SessionStart + UserPromptSubmit");
            ctx.note("  (pass --with-hooks to also wire standalone hooks in settings.json)");
            pushSkipped(ctx, "claude-hooks", "plugin manifest handles hooks");
        } else {
            ctx.note("  hooks: plugin install did not succeed; falling back to standalone wiring");
        }
    }

    if (wire) {
        ctx.say("  → installing hooks");
        const r = installHooks(ctx);
        if (std.mem.eql(u8, r, "ok")) {
            pushInstalled(ctx, "claude-hooks");
        } else if (std.mem.eql(u8, r, "skip")) {
            pushSkipped(ctx, "claude-hooks", "already wired");
        } else {
            pushFailed(ctx, "claude-hooks", r);
        }
    }

    if (opts.with_mcp_shrink) {
        ctx.say("  → wiring caveman-shrink MCP proxy (--with-mcp-shrink)");
        const r = installMcpShrink(ctx);
        if (std.mem.eql(u8, r.kind, "ok")) pushInstalled(ctx, "caveman-shrink");
        if (std.mem.eql(u8, r.kind, "skip")) pushSkipped(ctx, "caveman-shrink", r.why);
        if (std.mem.eql(u8, r.kind, "fail")) pushFailed(ctx, "caveman-shrink", r.why);
    }

    out("\n");
}

// ── installGemini ─────────────────────────────────────────────────────────────
fn installGemini(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say("→ Gemini CLI detected");

    if (!opts.force) {
        const probe_args = [_][:0]const u8{
            gpa.dupeZ(u8, "gemini") catch return,
            gpa.dupeZ(u8, "extensions") catch return,
            gpa.dupeZ(u8, "list") catch return,
        };
        if (captureSpawn(gpa, &probe_args)) |cap| {
            if (cap.status == 0 and containsCI(cap.stdout, "caveman")) {
                ctx.note("  caveman extension already installed (use --force to reinstall)");
                pushSkipped(ctx, "gemini", "extension already installed");
                out("\n");
                return;
            }
        }
    }
    const url = "https://github.com/" ++ REPO;
    const r = runSpawn(gpa, &.{ "gemini", "extensions", "install", url }, opts.dry_run);
    if (r == 0) pushInstalled(ctx, "gemini") else pushFailed(ctx, "gemini", "gemini extensions install failed");
    out("\n");
}

// ── installViaSkills ──────────────────────────────────────────────────────────
fn installViaSkills(ctx: *Ctx, prov: Provider) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say(fmt(ctx, "→ {s} detected", .{prov.label}));

    const profile = prov.profile.?;
    const r = runSpawn(gpa, &.{ "npx", "-y", "skills", "add", REPO, "--skill", "*", "-a", profile, "--yes" }, opts.dry_run);
    if (r == 0) pushInstalled(ctx, prov.id) else pushFailed(ctx, prov.id, fmt(ctx, "npx skills add ({s}) failed", .{profile}));
    out("\n");
}

// ── installOpencode (native plugin copy + AGENTS.md, reuses opencode_agent) ────
fn installOpencode(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say("→ opencode detected");

    const repo_root = ctx.repo_root orelse {
        ctx.warn("  opencode native install requires a local clone of the caveman repo.");
        ctx.note("  Re-run from a clone: git clone https://github.com/" ++ REPO ++ " && cd caveman && node bin/install.js --only opencode");
        pushFailed(ctx, "opencode", "native install requires local repo clone");
        out("\n");
        return;
    };

    const dir = opencodeConfigDir(gpa);
    const plugin_dir = std.fs.path.join(gpa, &.{ dir, "plugins", "caveman" }) catch return;
    const commands_dir = std.fs.path.join(gpa, &.{ dir, "commands" }) catch return;
    const agents_dir = std.fs.path.join(gpa, &.{ dir, "agents" }) catch return;
    const skills_dir = std.fs.path.join(gpa, &.{ dir, "skills" }) catch return;
    const opencode_json = std.fs.path.join(gpa, &.{ dir, "opencode.json" }) catch return;
    const agents_md = std.fs.path.join(gpa, &.{ dir, "AGENTS.md" }) catch return;

    if (opts.dry_run) {
        ctx.note(fmt(ctx, "  would mkdir {s}/, {s}/, {s}/, {s}/", .{ plugin_dir, commands_dir, agents_dir, skills_dir }));
        ctx.note(fmt(ctx, "  would copy plugin.js + package.json + caveman-config.cjs into {s}/", .{plugin_dir}));
        ctx.note(fmt(ctx, "  would copy {d} command files into {s}/", .{ OPENCODE_COMMAND_FILES.len, commands_dir }));
        ctx.note(fmt(ctx, "  would copy {d} cavecrew agents into {s}/", .{ OPENCODE_AGENT_FILES.len, agents_dir }));
        ctx.note(fmt(ctx, "  would copy {d} skill dirs into {s}/", .{ OPENCODE_SKILL_DIRS.len, skills_dir }));
        ctx.note(fmt(ctx, "  would patch {s} with \"plugin\" entry{s}", .{ opencode_json, if (opts.with_mcp_shrink) " + caveman-shrink MCP" else "" }));
        ctx.note(fmt(ctx, "  would write Tier-3 ruleset to {s}", .{agents_md}));
        pushInstalled(ctx, "opencode");
        out("\n");
        return;
    }

    // 1. Plugin dir.
    if (!mkdirP(plugin_dir)) {
        pushFailed(ctx, "opencode", "unsafe plugin directory");
        out("\n");
        return;
    }
    const plugin_src = std.fs.path.join(gpa, &.{ repo_root, "src", "plugins", "opencode" }) catch return;
    {
        const PayloadPair = struct { src: []const u8, dest: []const u8 };
        const payload = [_]PayloadPair{
            .{ .src = std.fs.path.join(gpa, &.{ plugin_src, "plugin.js" }) catch return, .dest = std.fs.path.join(gpa, &.{ plugin_dir, "plugin.js" }) catch return },
            .{ .src = std.fs.path.join(gpa, &.{ plugin_src, "package.json" }) catch return, .dest = std.fs.path.join(gpa, &.{ plugin_dir, "package.json" }) catch return },
            .{ .src = std.fs.path.join(gpa, &.{ repo_root, "src", "hooks", "caveman-config.js" }) catch return, .dest = std.fs.path.join(gpa, &.{ plugin_dir, "caveman-config.cjs" }) catch return },
        };
        for (payload) |p| {
            if (isFileReal(p.dest) and !opts.force) {
                ctx.note(fmt(ctx, "  skipped {s} (exists; --force to overwrite)", .{p.dest}));
                continue;
            }
            _ = copyFile(gpa, p.src, p.dest);
        }
    }
    out(fmt(ctx, "  installed: {s}\n", .{plugin_dir}));

    // 2. Commands.
    if (!mkdirP(commands_dir)) {
        pushFailed(ctx, "opencode", "unsafe commands directory");
        out("\n");
        return;
    }
    const cmd_src_dir = std.fs.path.join(gpa, &.{ plugin_src, "commands" }) catch return;
    for (OPENCODE_COMMAND_FILES) |f| {
        const s = std.fs.path.join(gpa, &.{ cmd_src_dir, f }) catch continue;
        const d = std.fs.path.join(gpa, &.{ commands_dir, f }) catch continue;
        if (!isFileReal(s)) continue;
        if (isFileReal(d) and !opts.force) {
            ctx.note(fmt(ctx, "  skipped {s} (exists; --force to overwrite)", .{d}));
            continue;
        }
        _ = copyFile(gpa, s, d);
        out(fmt(ctx, "  installed: {s}\n", .{d}));
    }

    // 3. Subagents — strip tools: via opencode_agent.stripOpencodeAgentTools.
    if (!mkdirP(agents_dir)) {
        pushFailed(ctx, "opencode", "unsafe agents directory");
        out("\n");
        return;
    }
    const agent_src_dir = std.fs.path.join(gpa, &.{ repo_root, "agents" }) catch return;
    for (OPENCODE_AGENT_FILES) |f| {
        const s = std.fs.path.join(gpa, &.{ agent_src_dir, f }) catch continue;
        const d = std.fs.path.join(gpa, &.{ agents_dir, f }) catch continue;
        if (!isFileReal(s)) continue;
        if (isFileReal(d) and !opts.force) {
            ctx.note(fmt(ctx, "  skipped {s} (exists; --force to overwrite)", .{d}));
            continue;
        }
        const raw = common.readFileAlloc(gpa, s, 16 * 1024 * 1024) orelse continue;
        const stripped = opencode_agent.stripOpencodeAgentTools(gpa, raw) catch continue;
        writeFile0644(d, stripped) catch continue;
        out(fmt(ctx, "  installed: {s}\n", .{d}));
    }

    // 4. Skills.
    if (!mkdirP(skills_dir)) {
        pushFailed(ctx, "opencode", "unsafe skills directory");
        out("\n");
        return;
    }
    const skill_src_dir = std.fs.path.join(gpa, &.{ repo_root, "skills" }) catch return;
    for (OPENCODE_SKILL_DIRS) |name| {
        const s = std.fs.path.join(gpa, &.{ skill_src_dir, name }) catch continue;
        const d = std.fs.path.join(gpa, &.{ skills_dir, name }) catch continue;
        if (!isDirReal(s)) continue;
        if (isDirReal(d) and !opts.force) {
            ctx.note(fmt(ctx, "  skipped {s}/ (exists; --force to overwrite)", .{d}));
            continue;
        }
        copyDirRecursive(gpa, s, d);
        out(fmt(ctx, "  installed: {s}/\n", .{d}));
    }

    // 5. AGENTS.md ruleset (fenced).
    {
        const rule_path = std.fs.path.join(gpa, &.{ repo_root, "src", "rules", "caveman-activate.md" }) catch return;
        const rule_raw = common.readFileAlloc(gpa, rule_path, 4 * 1024 * 1024) orelse {
            pushFailed(ctx, "opencode", "ruleset read failed");
            out("\n");
            return;
        };
        const rule_body = std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, rule_raw, " \t\r\n"), "\n" }) catch return;
        const fenced = std.mem.concat(gpa, u8, &.{ OPENCODE_AGENTS_MD_BEGIN, "\n", rule_body, OPENCODE_AGENTS_MD_END, "\n" }) catch return;

        if (common.existsNoFollow(agents_md)) {
            if (!common.isRegularFileNoSymlink(agents_md)) {
                pushFailed(ctx, "opencode", "unsafe AGENTS.md");
                out("\n");
                return;
            }
            const existing = common.readFileAlloc(gpa, agents_md, 4 * 1024 * 1024) orelse {
                pushFailed(ctx, "opencode", "AGENTS.md read failed");
                out("\n");
                return;
            };
            const fenced_present = std.mem.indexOf(u8, existing, OPENCODE_AGENTS_MD_BEGIN) != null and std.mem.indexOf(u8, existing, OPENCODE_AGENTS_MD_END) != null;
            const legacy = !fenced_present and std.mem.indexOf(u8, existing, OPENCODE_AGENTS_MD_SENTINEL) != null;
            if (fenced_present) {
                ctx.note(fmt(ctx, "  {s} already contains caveman ruleset", .{agents_md}));
            } else if (legacy) {
                ctx.note(fmt(ctx, "  {s} contains a legacy (un-fenced) caveman block — leaving as-is", .{agents_md}));
                ctx.note("  re-run with --force to replace it with a fenced block");
                if (opts.force) {
                    writeFile0644(agents_md, fenced) catch {
                        pushFailed(ctx, "opencode", "AGENTS.md write failed");
                        out("\n");
                        return;
                    };
                    out(fmt(ctx, "  rewrote {s} with fenced caveman block\n", .{agents_md}));
                }
            } else {
                const sep = if (std.mem.endsWith(u8, existing, "\n\n")) "" else if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n";
                const next = std.mem.concat(gpa, u8, &.{ existing, sep, fenced }) catch return;
                writeFile0644(agents_md, next) catch {
                    pushFailed(ctx, "opencode", "AGENTS.md write failed");
                    out("\n");
                    return;
                };
                out(fmt(ctx, "  appended caveman ruleset to {s}\n", .{agents_md}));
            }
        } else {
            writeFile0644(agents_md, fenced) catch {
                pushFailed(ctx, "opencode", "AGENTS.md write failed");
                out("\n");
                return;
            };
            out(fmt(ctx, "  installed: {s}\n", .{agents_md}));
        }
    }

    // 6. opencode.json — add plugin entry; optional caveman-shrink MCP.
    {
        if (readSettingsDoc(gpa, opencode_json)) |doc_const| {
            var doc = doc_const;
            defer doc.deinit();
            const arena = doc.arena;
            // .bak on first install only.
            const bak = std.mem.concat(gpa, u8, &.{ opencode_json, ".bak" }) catch opencode_json;
            if (isFileReal(opencode_json) and !pathExists(bak)) {
                _ = copyFile(gpa, opencode_json, bak);
            }
            if (doc.value != .object) doc.value = .{ .object = std.json.ObjectMap.init(arena) };
            // plugin array.
            if (doc.value.object.get("plugin") == null or doc.value.object.get("plugin").? != .array) {
                doc.value.object.put("plugin", .{ .array = std.json.Array.init(arena) }) catch {};
            }
            const plugin_ptr = doc.value.object.getPtr("plugin").?;
            var has_plugin = false;
            for (plugin_ptr.array.items) |it| {
                if (it == .string and std.mem.eql(u8, it.string, OPENCODE_PLUGIN_REL)) has_plugin = true;
            }
            if (!has_plugin) plugin_ptr.array.append(.{ .string = OPENCODE_PLUGIN_REL }) catch {};

            if (opts.with_mcp_shrink) {
                if (doc.value.object.get("mcp") == null or doc.value.object.get("mcp").? != .object) {
                    doc.value.object.put("mcp", .{ .object = std.json.ObjectMap.init(arena) }) catch {};
                }
                const mcp_ptr = doc.value.object.getPtr("mcp").?;
                if (mcp_ptr.object.get("caveman-shrink") == null) {
                    var entry = std.json.ObjectMap.init(arena);
                    entry.put("type", .{ .string = "local" }) catch {};
                    var cmd_arr = std.json.Array.init(arena);
                    cmd_arr.append(.{ .string = "npx" }) catch {};
                    cmd_arr.append(.{ .string = "-y" }) catch {};
                    cmd_arr.append(.{ .string = MCP_SHRINK_PKG }) catch {};
                    if (opts.mcp_shrink_cmd) |joined| {
                        var tit = std.mem.tokenizeAny(u8, joined, " ");
                        while (tit.next()) |tok| cmd_arr.append(.{ .string = arena.dupe(u8, tok) catch tok }) catch {};
                    }
                    entry.put("command", .{ .array = cmd_arr }) catch {};
                    entry.put("enabled", .{ .bool = true }) catch {};
                    mcp_ptr.object.put("caveman-shrink", .{ .object = entry }) catch {};
                    out(fmt(ctx, "  registered caveman-shrink MCP server (wraps: {s})\n", .{opts.mcp_shrink_cmd orelse ""}));
                }
            }
            writeSettingsFile(gpa, opencode_json, doc.value) catch {};
            out(fmt(ctx, "  patched: {s}\n", .{opencode_json}));
            pushInstalled(ctx, "opencode");
        } else {
            ctx.warn(fmt(ctx, "  {s} unparseable; will not touch it. Edit manually then re-run.", .{opencode_json}));
            pushFailed(ctx, "opencode", "opencode.json unparseable");
            out("\n");
            return;
        }
    }

    out("\n");
}

// ── installOpenclaw / installNullclaw (reuse zig modules) ─────────────────────
fn installOpenclaw(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say("→ OpenClaw detected");

    const ws = blk: {
        if (common.getenv("OPENCLAW_WORKSPACE")) |w| break :blk gpa.dupe(u8, w) catch w;
        break :blk openclaw.resolveWorkspace(gpa) catch {
            pushFailed(ctx, "openclaw", "cannot resolve workspace");
            out("\n");
            return;
        };
    };

    const skill_body = readRepoFile(ctx, "skills/caveman/SKILL.md") orelse "";
    const rule_body = readRepoFile(ctx, "src/rules/caveman-openclaw-bootstrap.md");
    const snippet = openclaw.loadBootstrapSnippet(gpa, rule_body) catch {
        pushFailed(ctx, "openclaw", "bootstrap snippet load failed");
        out("\n");
        return;
    };

    if (opts.dry_run) {
        const skill_file = std.fs.path.join(gpa, &.{ ws, "skills", "caveman", "SKILL.md" }) catch ws;
        const soul_file = std.fs.path.join(gpa, &.{ ws, "SOUL.md" }) catch ws;
        ctx.note(fmt(ctx, "  would write {s} (with version/always frontmatter)", .{skill_file}));
        ctx.note(fmt(ctx, "  would append to {s} (caveman bootstrap block)", .{soul_file}));
        pushInstalled(ctx, "openclaw");
        out("\n");
        return;
    }

    const r = openclaw.installOpenclaw(gpa, ws, skill_body, snippet, opts.dry_run, opts.force) catch {
        pushFailed(ctx, "openclaw", "install failed");
        out("\n");
        return;
    };
    if (r.ok) pushInstalled(ctx, "openclaw") else pushFailed(ctx, "openclaw", if (r.reason.len > 0) r.reason else "install failed");
    out("\n");
}

fn installNullclaw(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.results.detected += 1;
    ctx.say("→ NullClaw detected");

    const ws = blk: {
        if (common.getenv("NULLCLAW_WORKSPACE")) |w| break :blk gpa.dupe(u8, w) catch w;
        break :blk nullclaw.resolveWorkspace(gpa) catch {
            pushFailed(ctx, "nullclaw", "cannot resolve workspace");
            out("\n");
            return;
        };
    };

    const skill_body = readRepoFile(ctx, "skills/caveman/SKILL.md") orelse "";

    if (opts.dry_run) {
        const skill_file = std.fs.path.join(gpa, &.{ ws, "skills", "caveman", "SKILL.md" }) catch ws;
        ctx.note(fmt(ctx, "  would write {s} (with version/always frontmatter)", .{skill_file}));
        pushInstalled(ctx, "nullclaw");
        out("\n");
        return;
    }

    const r = nullclaw.installNullclaw(gpa, ws, skill_body, opts.dry_run, opts.force) catch {
        pushFailed(ctx, "nullclaw", "install failed");
        out("\n");
        return;
    };
    if (r.ok) pushInstalled(ctx, "nullclaw") else pushFailed(ctx, "nullclaw", if (r.reason.len > 0) r.reason else "install failed");
    out("\n");
}

fn readRepoFile(ctx: *Ctx, rel: []const u8) ?[]u8 {
    const root = ctx.repo_root orelse return null;
    const full = std.fs.path.join(ctx.gpa, &.{ root, rel }) catch return null;
    return common.readFileAlloc(ctx.gpa, full, 16 * 1024 * 1024);
}

// ── installHooks (local-clone copy path; download DEFERRED to R4c) ────────────
fn installHooks(ctx: *Ctx) []const u8 {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    const hooks_dir = std.fs.path.join(gpa, &.{ ctx.config_dir, "hooks" }) catch return "alloc failed";
    const settings_path = std.fs.path.join(gpa, &.{ ctx.config_dir, "settings.json" }) catch return "alloc failed";
    const source_dir: ?[]const u8 = if (ctx.repo_root) |r| std.fs.path.join(gpa, &.{ r, "src", "hooks" }) catch null else null;

    if (opts.dry_run) {
        ctx.note(fmt(ctx, "  would mkdir -p {s}", .{hooks_dir}));
        for (HOOK_FILES) |f| {
            const d = std.fs.path.join(gpa, &.{ hooks_dir, f }) catch continue;
            ctx.note(fmt(ctx, "  would install {s}", .{d}));
        }
        ctx.note(fmt(ctx, "  would merge SessionStart + UserPromptSubmit + statusline into {s}", .{settings_path}));
        return "ok";
    }

    if (!mkdirP(hooks_dir)) return "mkdir hooks failed";

    // Copy each hook file from the local clone. The remote-download + SHA-256
    // verify fallback is DEFERRED to R4c (network path). Without a clone we
    // cannot proceed.
    for (HOOK_FILES) |f| {
        const dest = std.fs.path.join(gpa, &.{ hooks_dir, f }) catch return "alloc failed";
        const src: ?[]const u8 = if (source_dir) |sd| std.fs.path.join(gpa, &.{ sd, f }) catch null else null;
        if (src != null and isFileReal(src.?)) {
            if (!copyFile(gpa, src.?, dest)) return fmt(ctx, "copy {s} failed", .{f});
        } else {
            return fmt(ctx, "download {s} not supported in this build (R4c) — run from a local clone", .{f});
        }
        out(fmt(ctx, "  installed: {s}\n", .{dest}));
    }

    // chmod statusline.sh 0755.
    {
        const sl = std.fs.path.join(gpa, &.{ hooks_dir, "caveman-statusline.sh" }) catch hooks_dir;
        var b: [std.fs.max_path_bytes]u8 = undefined;
        if (common.toZ(&b, sl)) |z| {
            _ = c.chmod(z, 0o755);
        } else |_| {}
    }

    // Merge into settings.json.
    var doc = readSettingsDoc(gpa, settings_path) orelse {
        ctx.warn("  settings.json unparseable; will not touch it. Edit manually then re-run.");
        return "settings.json unparseable";
    };
    defer doc.deinit();
    const arena = doc.arena;

    // Backup once.
    {
        const bak = std.mem.concat(gpa, u8, &.{ settings_path, ".bak" }) catch settings_path;
        if (isFileReal(settings_path) and !pathExists(bak)) _ = copyFile(gpa, settings_path, bak);
    }

    const node = nodePath(gpa);
    const activate = std.fs.path.join(gpa, &.{ hooks_dir, "caveman-activate.js" }) catch hooks_dir;
    const tracker = std.fs.path.join(gpa, &.{ hooks_dir, "caveman-mode-tracker.js" }) catch hooks_dir;
    const statusline = std.fs.path.join(gpa, &.{ hooks_dir, "caveman-statusline.sh" }) catch hooks_dir;

    _ = settings.rewriteLegacyManagedHookCommands(arena, &doc.value, node) catch 0;

    _ = settings.addCommandHook(arena, &doc.value, "SessionStart", .{
        .command = fmt(ctx, "\"{s}\" \"{s}\"", .{ node, activate }),
        .marker = "caveman-activate",
        .timeout = 5,
        .status_message = "Loading caveman mode...",
    }) catch {};

    _ = settings.addCommandHook(arena, &doc.value, "UserPromptSubmit", .{
        .command = fmt(ctx, "\"{s}\" \"{s}\"", .{ node, tracker }),
        .marker = "caveman-mode-tracker",
        .timeout = 5,
        .status_message = "Tracking caveman mode...",
    }) catch {};

    // Statusline (POSIX: bash "<statusline>"). Windows path is out of scope.
    {
        const sl_cmd = fmt(ctx, "bash \"{s}\"", .{statusline});
        if (doc.value == .object and doc.value.object.get("statusLine") == null) {
            var slo = std.json.ObjectMap.init(doc.arena);
            slo.put("type", .{ .string = "command" }) catch {};
            slo.put("command", .{ .string = sl_cmd }) catch {};
            doc.value.object.put("statusLine", .{ .object = slo }) catch {};
            out("  statusline badge configured.\n");
        } else if (doc.value == .object) {
            const sl_val = doc.value.object.get("statusLine").?;
            const existing = switch (sl_val) {
                .string => |s| s,
                .object => |o| if (o.get("command")) |cv| (if (cv == .string) cv.string else "") else "",
                else => "",
            };
            if (std.mem.indexOf(u8, existing, statusline) != null or std.mem.indexOf(u8, existing, "caveman-statusline") != null) {
                out("  statusline badge already configured.\n");
            } else {
                out("  NOTE: existing statusline detected — caveman badge NOT added.\n");
                out("        See src/hooks/README.md to add the badge to your existing statusline.\n");
            }
        }
    }

    settings.validateHookFields(arena, &doc.value) catch {};
    writeSettingsFile(gpa, settings_path, doc.value) catch {};
    out(fmt(ctx, "  hooks wired in {s}\n", .{settings_path}));
    return "ok";
}

fn nodePath(gpa: std.mem.Allocator) []const u8 {
    // The JS installer uses process.execPath — the absolute path to the node
    // binary running it — so hooks/init are invoked with an explicit interpreter
    // path. This standalone Zig binary has no node process, so we resolve the
    // absolute path of `node` on PATH via `command -v` (the closest analogue).
    // Falls back to the bare name if resolution fails.
    const argv = [_][:0]const u8{
        gpa.dupeZ(u8, "/bin/sh") catch return "node",
        gpa.dupeZ(u8, "-c") catch return "node",
        gpa.dupeZ(u8, "command -v node") catch return "node",
    };
    if (captureSpawn(gpa, &argv)) |cap| {
        if (cap.status == 0) {
            const trimmed = std.mem.trim(u8, cap.stdout, " \t\r\n");
            if (trimmed.len > 0) return gpa.dupe(u8, trimmed) catch "node";
        }
    }
    return "node";
}

// ── installMcpShrink ──────────────────────────────────────────────────────────
const McpResult = struct { kind: []const u8, why: []const u8 = "" };

fn installMcpShrink(ctx: *Ctx) McpResult {
    const gpa = ctx.gpa;
    const opts = ctx.opts;

    const probe_args = [_][:0]const u8{
        gpa.dupeZ(u8, "npm") catch return .{ .kind = "fail", .why = "alloc" },
        gpa.dupeZ(u8, "view") catch return .{ .kind = "fail", .why = "alloc" },
        gpa.dupeZ(u8, MCP_SHRINK_PKG) catch return .{ .kind = "fail", .why = "alloc" },
        gpa.dupeZ(u8, "name") catch return .{ .kind = "fail", .why = "alloc" },
    };
    const probe = captureSpawn(gpa, &probe_args) orelse Capture{ .status = 1, .stdout = "" };
    if (probe.status != 0) {
        ctx.warn(fmt(ctx, "    'npm view {s}' returned no metadata — registry unreachable or package missing.", .{MCP_SHRINK_PKG}));
        ctx.note("    Skipping registration. Re-run --with-mcp-shrink when the registry is reachable.");
        return .{ .kind = "skip", .why = "npm registry probe failed" };
    }
    const help_args = [_][:0]const u8{
        gpa.dupeZ(u8, "claude") catch return .{ .kind = "fail", .why = "alloc" },
        gpa.dupeZ(u8, "mcp") catch return .{ .kind = "fail", .why = "alloc" },
        gpa.dupeZ(u8, "--help") catch return .{ .kind = "fail", .why = "alloc" },
    };
    const help = captureSpawn(gpa, &help_args) orelse Capture{ .status = 1, .stdout = "" };
    if (help.status != 0) {
        ctx.note("    'claude mcp add' not available on this CLI. Add the snippet from");
        ctx.note("    src/hooks/README.md to your Claude Code MCP config manually.");
        return .{ .kind = "skip", .why = "manual config required" };
    }
    const upstream = opts.mcp_shrink_cmd orelse "";
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(gpa, &.{ "claude", "mcp", "add", "caveman-shrink", "--", "npx", "-y", MCP_SHRINK_PKG }) catch {};
    var tit = std.mem.tokenizeAny(u8, upstream, " ");
    while (tit.next()) |tok| args.append(gpa, tok) catch {};
    const r = runSpawn(gpa, args.items, opts.dry_run);
    if (r == 0) {
        ctx.note(fmt(ctx, "    registered, wrapping: {s}", .{upstream}));
        ctx.note("    Edit ~/.claude.json mcpServers[\"caveman-shrink\"] to change the upstream,");
        ctx.note("    or `claude mcp remove caveman-shrink` to drop it.");
        ctx.note("    Docs: https://github.com/" ++ REPO ++ "/tree/main/src/mcp-servers/caveman-shrink");
        return .{ .kind = "ok" };
    }
    return .{ .kind = "fail", .why = "claude mcp add failed" };
}

// ── runInit (dispatch to caveman-init binary, then node script) ───────────────
fn runInit(ctx: *Ctx) bool {
    const gpa = ctx.gpa;
    const opts = ctx.opts;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse return false;
    const cwd = gpa.dupe(u8, std.mem.sliceTo(cwd_z, 0)) catch return false;

    // Build the trailing init args (target + flags + --only ids).
    var init_args: std.ArrayList([]const u8) = .empty;
    init_args.append(gpa, cwd) catch {};
    if (opts.dry_run) init_args.append(gpa, "--dry-run") catch {};
    if (opts.force) init_args.append(gpa, "--force") catch {};
    // De-dup init_only preserving order.
    var seen: std.ArrayList([]const u8) = .empty;
    for (opts.init_only.items) |id| {
        if (inList(seen.items, id)) continue;
        seen.append(gpa, id) catch {};
        init_args.append(gpa, "--only") catch {};
        init_args.append(gpa, id) catch {};
    }
    if (opts.only.items.len > 0 and seen.items.len == 0) {
        ctx.note("  no repo-local init target matches selected --only agent(s); skipping");
        return true;
    }

    // Prefer the local src/tools/caveman-init.js (mirror JS). If a clone exists,
    // run it via node. Otherwise refuse (no detached single-file path).
    if (ctx.repo_root) |root| {
        const init_js = std.fs.path.join(gpa, &.{ root, "src/tools/caveman-init.js" }) catch null;
        if (init_js != null and isFileReal(init_js.?)) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.append(gpa, nodePath(gpa)) catch {};
            argv.append(gpa, init_js.?) catch {};
            argv.appendSlice(gpa, init_args.items) catch {};
            const r = runSpawn(gpa, argv.items, opts.dry_run);
            return r == 0;
        }
    }
    ctx.warn("  local src/tools/caveman-init.js not found; refusing detached single-file --with-init");
    ctx.warn("  run from a full package/clone so repo-local aliases use the matching init script");
    ctx.warn(fmt(ctx, "  skipped remote fallback: https://raw.githubusercontent.com/{s}/v1.9.0/src/tools/caveman-init.js", .{REPO}));
    return false;
}

// ── uninstall ─────────────────────────────────────────────────────────────────
fn uninstall(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    ctx.say("🪨 caveman uninstall");
    if (opts.dry_run) ctx.note("  (dry run — nothing will be removed)");

    const hooks_dir = std.fs.path.join(gpa, &.{ ctx.config_dir, "hooks" }) catch ctx.config_dir;
    const settings_path = std.fs.path.join(gpa, &.{ ctx.config_dir, "settings.json" }) catch ctx.config_dir;

    // Strip caveman hooks + statusline from settings.json (settings.zig).
    if (isFileReal(settings_path)) {
        if (readSettingsDoc(gpa, settings_path)) |doc_const| {
            var doc = doc_const;
            defer doc.deinit();
            const arena = doc.arena;
            const removed = settings.removeCavemanHooks(arena, &doc.value, "caveman") catch 0;
            if (doc.value == .object) {
                if (doc.value.object.get("statusLine")) |sl| {
                    const cmd = switch (sl) {
                        .string => |s| s,
                        .object => |o| if (o.get("command")) |cv| (if (cv == .string) cv.string else "") else "",
                        else => "",
                    };
                    if (std.mem.indexOf(u8, cmd, "caveman-statusline") != null) {
                        _ = doc.value.object.orderedRemove("statusLine");
                    }
                }
            }
            settings.validateHookFields(arena, &doc.value) catch {};
            if (!opts.dry_run) {
                if (writeSettingsFile(gpa, settings_path, doc.value)) {
                    ctx.ok(fmt(ctx, "  removed {d} caveman hook entr{s} from settings.json", .{ removed, if (removed == 1) "y" else "ies" }));
                } else |_| {
                    ctx.warn(fmt(ctx, "  could not update {s}", .{settings_path}));
                }
            } else {
                ctx.ok(fmt(ctx, "  removed {d} caveman hook entr{s} from settings.json", .{ removed, if (removed == 1) "y" else "ies" }));
            }
        }
    }

    // Delete hook files.
    if (common.classify(hooks_dir) == .dir) {
        for (HOOK_FILES) |f| {
            const p = std.fs.path.join(gpa, &.{ hooks_dir, f }) catch continue;
            if (!pathExists(p)) continue;
            if (!opts.dry_run) {
                var b: [std.fs.max_path_bytes]u8 = undefined;
                if (common.toZ(&b, p)) |z| _ = c.unlink(z) else |_| {}
            }
            ctx.note(fmt(ctx, "  removed {s}", .{p}));
        }
    }

    // Plugin uninstall on claude.
    if (hasCmd(gpa, "claude")) {
        const probe_args = [_][:0]const u8{
            gpa.dupeZ(u8, "claude") catch return,
            gpa.dupeZ(u8, "plugin") catch return,
            gpa.dupeZ(u8, "list") catch return,
        };
        const probe = captureSpawn(gpa, &probe_args) orelse Capture{ .status = 1, .stdout = "" };
        if (probe.status == 0 and containsCI(probe.stdout, "caveman")) {
            const r = runSpawn(gpa, &.{ "claude", "plugin", "uninstall", "caveman@caveman" }, opts.dry_run);
            if (r == 0) ctx.ok("  removed claude plugin");
        } else {
            ctx.note("  claude plugin not installed — skipping");
        }
        const mcp_help_args = [_][:0]const u8{
            gpa.dupeZ(u8, "claude") catch return,
            gpa.dupeZ(u8, "mcp") catch return,
            gpa.dupeZ(u8, "--help") catch return,
        };
        const mcp_help = captureSpawn(gpa, &mcp_help_args) orelse Capture{ .status = 1, .stdout = "" };
        if (mcp_help.status == 0) {
            _ = runSpawn(gpa, &.{ "claude", "mcp", "remove", "caveman-shrink" }, opts.dry_run);
        }
    }

    // Gemini extension.
    if (hasCmd(gpa, "gemini")) {
        const probe_args = [_][:0]const u8{
            gpa.dupeZ(u8, "gemini") catch return,
            gpa.dupeZ(u8, "extensions") catch return,
            gpa.dupeZ(u8, "list") catch return,
        };
        const probe = captureSpawn(gpa, &probe_args) orelse Capture{ .status = 1, .stdout = "" };
        if (probe.status == 0 and containsCI(probe.stdout, "caveman")) {
            _ = runSpawn(gpa, &.{ "gemini", "extensions", "uninstall", "caveman" }, opts.dry_run);
        } else {
            ctx.note("  gemini extension not installed — skipping");
        }
    }

    // opencode native install — strip plugin/mcp entries + our files.
    uninstallOpencode(ctx);

    // OpenClaw native install.
    {
        const ws = blk: {
            if (common.getenv("OPENCLAW_WORKSPACE")) |w| break :blk gpa.dupe(u8, w) catch w;
            const home = common.getenv("HOME") orelse break :blk "";
            break :blk std.fs.path.join(gpa, &.{ home, ".openclaw", "workspace" }) catch "";
        };
        const skill = std.fs.path.join(gpa, &.{ ws, "skills", "caveman" }) catch "";
        const soul = std.fs.path.join(gpa, &.{ ws, "SOUL.md" }) catch "";
        if (common.classify(skill) == .dir or common.isRegularFileNoSymlink(soul)) {
            // The stage-1 openclaw.uninstallOpenclaw module is silent; emit the
            // same per-file notes the JS log object produced (existence-gated,
            // dry-run wording matches bin/lib/openclaw.js uninstallOpenclaw).
            if (common.classify(skill) == .dir) {
                ctx.note(if (opts.dry_run) fmt(ctx, "  would remove {s}/", .{skill}) else fmt(ctx, "  removed {s}", .{skill}));
            }
            if (common.isRegularFileNoSymlink(soul)) {
                ctx.note(if (opts.dry_run) fmt(ctx, "  would strip caveman block from {s}", .{soul}) else fmt(ctx, "  stripped caveman block from {s}", .{soul}));
            }
            openclaw.uninstallOpenclaw(gpa, ws, opts.dry_run) catch {};
            ctx.ok("  pruned caveman entries from OpenClaw workspace");
        }
    }

    // NullClaw native install.
    {
        const ws = blk: {
            if (common.getenv("NULLCLAW_WORKSPACE")) |w| break :blk gpa.dupe(u8, w) catch w;
            break :blk nullclaw.resolveWorkspace(gpa) catch "";
        };
        const skill = std.fs.path.join(gpa, &.{ ws, "skills", "caveman" }) catch "";
        if (common.classify(skill) == .dir) {
            ctx.note(if (opts.dry_run) fmt(ctx, "  would remove {s}/", .{skill}) else fmt(ctx, "  removed {s}", .{skill}));
            nullclaw.uninstallNullclaw(gpa, ws, opts.dry_run) catch {};
            ctx.ok("  pruned caveman skill from NullClaw workspace");
        }
    }

    // Flag file.
    {
        const flag = std.fs.path.join(gpa, &.{ ctx.config_dir, ".caveman-active" }) catch "";
        if (pathExists(flag) and !opts.dry_run) {
            var b: [std.fs.max_path_bytes]u8 = undefined;
            if (common.toZ(&b, flag)) |z| _ = c.unlink(z) else |_| {}
        }
    }

    out("\n");
    ctx.ok("uninstall done.");
    ctx.ok("npx-skills installs (Cursor/Windsurf/etc.) — remove via your IDE's skill manager");
    ctx.ok("per-repo init files (.cursor/, .windsurf/, AGENTS.md) — remove with your editor");
}

fn uninstallOpencode(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    const opts = ctx.opts;
    const dir = opencodeConfigDir(gpa);
    const plugin_dir = std.fs.path.join(gpa, &.{ dir, "plugins", "caveman" }) catch return;
    const plugin_kind = common.classify(plugin_dir);
    if (plugin_kind == .missing) return;

    const oc_json = std.fs.path.join(gpa, &.{ dir, "opencode.json" }) catch return;
    if (isFileReal(oc_json)) {
        if (readSettingsDoc(gpa, oc_json)) |doc_const| {
            var doc = doc_const;
            defer doc.deinit();
            if (doc.value == .object) {
                if (doc.value.object.getPtr("plugin")) |pp| {
                    if (pp.* == .array) {
                        var kept = std.json.Array.init(doc.arena);
                        for (pp.array.items) |it| {
                            if (it == .string and std.mem.eql(u8, it.string, OPENCODE_PLUGIN_REL)) continue;
                            kept.append(it) catch {};
                        }
                        if (kept.items.len == 0) {
                            _ = doc.value.object.orderedRemove("plugin");
                        } else {
                            pp.array = kept;
                        }
                    }
                }
                if (doc.value.object.getPtr("mcp")) |mp| {
                    if (mp.* == .object and mp.object.get("caveman-shrink") != null) {
                        _ = mp.object.orderedRemove("caveman-shrink");
                        if (mp.object.count() == 0) _ = doc.value.object.orderedRemove("mcp");
                    }
                }
            }
            if (!opts.dry_run) writeSettingsFile(gpa, oc_json, doc.value) catch {};
            ctx.ok(fmt(ctx, "  pruned caveman entries from {s}", .{oc_json}));
        }
    }
    if (plugin_kind == .symlink) {
        ctx.warn(fmt(ctx, "  left symlinked opencode plugin dir in place: {s}", .{plugin_dir}));
    } else {
        if (!opts.dry_run) openclaw.removeTree(gpa, plugin_dir);
        ctx.note(fmt(ctx, "  removed {s}", .{plugin_dir}));
    }

    for (OPENCODE_COMMAND_FILES) |f| {
        const p = std.fs.path.join(gpa, &.{ dir, "commands", f }) catch continue;
        if (pathExists(p) and !opts.dry_run) {
            var b: [std.fs.max_path_bytes]u8 = undefined;
            if (common.toZ(&b, p)) |z| _ = c.unlink(z) else |_| {}
        }
    }
    for (OPENCODE_AGENT_FILES) |f| {
        const p = std.fs.path.join(gpa, &.{ dir, "agents", f }) catch continue;
        if (pathExists(p) and !opts.dry_run) {
            var b: [std.fs.max_path_bytes]u8 = undefined;
            if (common.toZ(&b, p)) |z| _ = c.unlink(z) else |_| {}
        }
    }
    for (OPENCODE_SKILL_DIRS) |name| {
        const p = std.fs.path.join(gpa, &.{ dir, "skills", name }) catch continue;
        if (common.classify(p) != .missing and !opts.dry_run) openclaw.removeTree(gpa, p);
    }

    // AGENTS.md fenced-block strip.
    const oc_agents = std.fs.path.join(gpa, &.{ dir, "AGENTS.md" }) catch return;
    if (common.isRegularFileNoSymlink(oc_agents)) {
        const body = common.readFileAlloc(gpa, oc_agents, 4 * 1024 * 1024) orelse return;
        const begin = std.mem.indexOf(u8, body, OPENCODE_AGENTS_MD_BEGIN);
        const end = std.mem.indexOf(u8, body, OPENCODE_AGENTS_MD_END);
        if (begin != null and end != null and end.? > begin.?) {
            const before = std.mem.trimEnd(u8, body[0..begin.?], "\n");
            const after_raw = body[end.? + OPENCODE_AGENTS_MD_END.len ..];
            const after = std.mem.trimStart(u8, after_raw, "\n");
            var joined: std.ArrayList(u8) = .empty;
            joined.appendSlice(gpa, before) catch {};
            if (after.len > 0) {
                joined.append(gpa, '\n') catch {};
                joined.appendSlice(gpa, after) catch {};
            }
            const trimmed = std.mem.trimEnd(u8, joined.items, " \t\r\n");
            const next: []const u8 = if (trimmed.len > 0) std.mem.concat(gpa, u8, &.{ trimmed, "\n" }) catch "" else "";
            if (!opts.dry_run) {
                if (next.len == 0) {
                    var b: [std.fs.max_path_bytes]u8 = undefined;
                    if (common.toZ(&b, oc_agents)) |z| _ = c.unlink(z) else |_| {}
                } else {
                    writeFile0644(oc_agents, next) catch {};
                }
            }
            ctx.note(if (next.len == 0) fmt(ctx, "  removed {s}", .{oc_agents}) else fmt(ctx, "  stripped caveman block from {s}", .{oc_agents}));
        } else if (std.mem.indexOf(u8, body, OPENCODE_AGENTS_MD_SENTINEL) != null) {
            const bt = std.mem.trim(u8, body, " \t\r\n");
            if (bt.len == 0 or std.mem.startsWith(u8, bt, OPENCODE_AGENTS_MD_SENTINEL)) {
                if (!opts.dry_run) {
                    var b: [std.fs.max_path_bytes]u8 = undefined;
                    if (common.toZ(&b, oc_agents)) |z| _ = c.unlink(z) else |_| {}
                }
                ctx.note(fmt(ctx, "  removed {s}", .{oc_agents}));
            } else {
                ctx.note(fmt(ctx, "  left {s} in place (legacy mixed content — strip caveman block manually)", .{oc_agents}));
            }
        }
    }

    // opencode flag file.
    const oc_flag = std.fs.path.join(gpa, &.{ dir, ".caveman-active" }) catch return;
    if (pathExists(oc_flag) and !opts.dry_run) {
        var b: [std.fs.max_path_bytes]u8 = undefined;
        if (common.toZ(&b, oc_flag)) |z| _ = c.unlink(z) else |_| {}
    }
}

// ── Summary + main ────────────────────────────────────────────────────────────
fn printSummary(ctx: *Ctx) u8 {
    out("\n");
    ctx.say("🪨 done");
    if (ctx.results.installed.items.len > 0) {
        ctx.ok("  installed:");
        for (ctx.results.installed.items) |a| out(fmt(ctx, "    • {s}\n", .{a}));
    }
    if (ctx.results.skipped.items.len > 0) {
        out("  skipped:\n");
        for (ctx.results.skipped.items) |kv| out(fmt(ctx, "    • {s} — {s}\n", .{ kv[0], kv[1] }));
    }
    if (ctx.results.failed.items.len > 0) {
        ctx.warn("  failed:");
        for (ctx.results.failed.items) |kv| err(fmt(ctx, "    • {s} — {s}\n", .{ kv[0], kv[1] }));
    }
    if (ctx.results.installed.items.len == 0 and ctx.results.skipped.items.len == 0 and ctx.results.failed.items.len == 0) {
        out("  nothing detected. run with --list to see all 30+ supported agents,\n");
        out("  or pass --only <agent> to force a specific target.\n");
    }
    out("\n");
    ctx.note("  start any session and say 'caveman mode', or run /caveman in Claude Code");
    ctx.note("  uninstall: npx -y github:" ++ REPO ++ " -- --uninstall");

    if (ctx.results.failed.items.len > 0 and ctx.results.installed.items.len == 0 and ctx.results.skipped.items.len == 0) return 1;
    if (ctx.results.detected > 0 and ctx.results.installed.items.len == 0 and ctx.results.skipped.items.len == 0) return 1;
    return 0;
}

fn want(opts: *Opts, id: []const u8) bool {
    if (opts.only.items.len == 0) return true;
    return inList(opts.only.items, id);
}
fn explicit(opts: *Opts, id: []const u8) bool {
    return inList(opts.only.items, id);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    {
        var it = init.args.iterate();
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |a| argv.append(gpa, gpa.dupe(u8, a) catch continue) catch {};
    }

    var opts = parseArgs(gpa, argv.items);

    if (opts.help) {
        printHelp();
        std.process.exit(0);
    }
    if (opts.list_only) {
        printList(gpa, opts.no_color);
        std.process.exit(0);
    }

    const config_dir = opts.config_dir orelse blk: {
        if (common.getenv("CLAUDE_CONFIG_DIR")) |d| break :blk gpa.dupe(u8, d) catch d;
        const home = common.getenv("HOME") orelse break :blk "";
        break :blk std.fs.path.join(gpa, &.{ home, ".claude" }) catch "";
    };
    const repo_root = detectRepoRoot(gpa);

    var results: Results = .{};
    var ctx: Ctx = .{
        .gpa = gpa,
        .opts = &opts,
        .config_dir = config_dir,
        .repo_root = repo_root,
        .results = &results,
        .color = makeChalk(opts.no_color),
    };

    if (opts.uninstall) {
        uninstall(&ctx);
        std.process.exit(0);
    }

    ctx.say("🪨 caveman installer");
    ctx.note("  " ++ REPO);
    if (opts.dry_run) ctx.note("  (dry run — nothing will be written)");
    out("\n");

    // Run installs in declared order. Soft providers auto-skip unless --only.
    for (PROVIDERS) |prov| {
        if (!want(&opts, prov.id)) continue;
        if (prov.soft and !explicit(&opts, prov.id)) continue;
        if (!explicit(&opts, prov.id) and !detectMatch(gpa, prov.detect)) continue;

        if (std.mem.eql(u8, prov.id, "claude")) {
            installClaude(&ctx);
        } else if (std.mem.eql(u8, prov.id, "gemini")) {
            installGemini(&ctx);
        } else if (std.mem.eql(u8, prov.id, "opencode")) {
            installOpencode(&ctx);
        } else if (std.mem.eql(u8, prov.id, "openclaw")) {
            installOpenclaw(&ctx);
        } else if (std.mem.eql(u8, prov.id, "nullclaw")) {
            installNullclaw(&ctx);
        } else if (prov.profile != null) {
            installViaSkills(&ctx, prov);
        }
    }

    // Auto-detect npx-skills fallback if nothing matched.
    if (!opts.skip_skills and opts.only.items.len == 0 and results.detected == 0) {
        ctx.say("→ no known agents detected — running npx-skills auto-detect fallback");
        const r = runSpawn(gpa, &.{ "npx", "-y", "skills", "add", REPO, "--yes", "--all" }, opts.dry_run);
        if (r == 0) pushInstalled(&ctx, "skills-auto") else pushFailed(&ctx, "skills-auto", "npx skills add (auto) failed");
        out("\n");
    }

    // Per-repo init.
    if (opts.with_init) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_z = c.getcwd(&cwd_buf, cwd_buf.len) orelse "";
        const cwd = std.mem.sliceTo(cwd_z, 0);
        ctx.say(fmt(&ctx, "→ writing per-repo IDE rule files into {s} (--with-init)", .{cwd}));
        if (runInit(&ctx)) {
            pushInstalled(&ctx, fmt(&ctx, "caveman-init ({s})", .{cwd}));
        } else {
            pushFailed(&ctx, "caveman-init", "src/tools/caveman-init.js failed");
        }
        out("\n");
    } else if (results.installed.items.len > 0 or results.skipped.items.len > 0) {
        ctx.note("  tip: re-run inside a repo with --all (or --with-init) to also write per-repo");
        ctx.note("       Cursor/Windsurf/Cline/Copilot/AGENTS.md rule files.");
    }

    const code = printSummary(&ctx);
    std.process.exit(code);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "parseArgs basic flags" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var opts = parseArgs(a, &.{ "--dry-run", "--force", "--no-color", "--non-interactive" });
    try testing.expect(opts.dry_run);
    try testing.expect(opts.force);
    try testing.expect(opts.no_color);
    try testing.expect(opts.non_interactive);
    try testing.expect(!opts.all);
    try testing.expect(opts.with_hooks == .auto);
    opts.only.deinit(a);
    opts.init_only.deinit(a);
}

test "parseArgs --all turns on init, leaves hooks auto" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{"--all"});
    try testing.expect(opts.all);
    try testing.expect(opts.with_init);
    try testing.expect(opts.with_hooks == .auto);
    try testing.expect(!opts.with_mcp_shrink);
}

test "parseArgs --minimal turns everything off" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{"--minimal"});
    try testing.expect(opts.minimal);
    try testing.expect(opts.with_hooks == .off);
    try testing.expect(!opts.with_init);
    try testing.expect(!opts.with_mcp_shrink);
}

test "parseArgs --no-hooks / --with-hooks" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parseArgs(a, &.{"--no-hooks"}).with_hooks == .off);
    try testing.expect(parseArgs(a, &.{"--with-hooks"}).with_hooks == .on);
}

test "parseArgs --with-mcp-shrink=value tokenizes + joins" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{"--with-mcp-shrink=npx   server  /tmp"});
    try testing.expect(opts.with_mcp_shrink);
    try testing.expectEqualStrings("npx server /tmp", opts.mcp_shrink_cmd.?);
}

test "parseArgs --with-mcp-shrink space form" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{ "--with-mcp-shrink", "npx server /x" });
    try testing.expect(opts.with_mcp_shrink);
    try testing.expectEqualStrings("npx server /x", opts.mcp_shrink_cmd.?);
}

test "parseArgs --only resolves aliases + records init targets" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{ "--only", "claude-code", "--only", "codex-cli" });
    try testing.expectEqual(@as(usize, 2), opts.only.items.len);
    try testing.expectEqualStrings("claude", opts.only.items[0]); // claude-code → claude
    try testing.expectEqualStrings("codex", opts.only.items[1]); // codex-cli → codex
}

test "parseArgs --only normalizes underscores + case" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = parseArgs(a, &.{ "--only", "AIDER_DESK" });
    try testing.expectEqualStrings("aider-desk", opts.only.items[0]);
}

test "resolveProviderOnlyId aliases" {
    try testing.expectEqualStrings("aider-desk", resolveProviderOnlyId("aider"));
    try testing.expectEqualStrings("warp", resolveProviderOnlyId("warp-preview"));
    try testing.expectEqualStrings("antigravity", resolveProviderOnlyId("antigravity-cli"));
    try testing.expectEqualStrings("codex", resolveProviderOnlyId("codex-app"));
    try testing.expectEqualStrings("cursor", resolveProviderOnlyId("cursor")); // passthrough
}

test "PROVIDERS has 35 entries with 3 soft" {
    try testing.expectEqual(@as(usize, 35), PROVIDERS.len);
    var soft: usize = 0;
    for (PROVIDERS) |p| {
        if (p.soft) soft += 1;
    }
    try testing.expectEqual(@as(usize, 3), soft);
    // soft providers are the last three.
    try testing.expect(PROVIDERS[PROVIDERS.len - 1].soft);
    try testing.expect(PROVIDERS[PROVIDERS.len - 2].soft);
    try testing.expect(PROVIDERS[PROVIDERS.len - 3].soft);
}

test "providerById finds and misses" {
    try testing.expect(providerById("claude") != null);
    try testing.expect(providerById("antigravity") != null);
    try testing.expect(providerById("nonexistent") == null);
    try testing.expectEqualStrings("Codex CLI", providerById("codex").?.label);
}

test "detectMatch dir clause + || alternation" {
    // detectMatch mirrors the production path: it allocates (expandHome,
    // shellEscape, path joins) into the caller's arena and never frees per-call,
    // so it's exercised with an arena here rather than the leak-checking
    // testing.allocator.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const dir_path = try common.makeTmpDir(gpa);

    // dir: clause hits an existing directory.
    const spec_dir = try std.fmt.allocPrint(gpa, "dir:{s}", .{dir_path});
    try testing.expect(detectMatch(gpa, spec_dir));

    // Missing dir → false.
    const spec_missing = try std.fmt.allocPrint(gpa, "dir:{s}/does-not-exist", .{dir_path});
    try testing.expect(!detectMatch(gpa, spec_missing));

    // || alternation: first clause misses, second hits.
    const spec_alt = try std.fmt.allocPrint(gpa, "dir:{s}/nope||dir:{s}", .{ dir_path, dir_path });
    try testing.expect(detectMatch(gpa, spec_alt));

    // command: clause for a binary that exists (sh is always present).
    try testing.expect(detectMatch(gpa, "command:sh"));
    try testing.expect(!detectMatch(gpa, "command:definitely-not-a-real-binary-xyz"));
}

test "detectMatch file clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const dir_path = try common.makeTmpDir(gpa);
    const f = try std.fs.path.join(gpa, &.{ dir_path, "marker" });
    try common.writeSmall(f, "x");
    const spec = try std.fmt.allocPrint(gpa, "file:{s}", .{f});
    try testing.expect(detectMatch(gpa, spec));
    // dir: on a regular file → false (isDirReal).
    const spec_dir = try std.fmt.allocPrint(gpa, "dir:{s}", .{f});
    try testing.expect(!detectMatch(gpa, spec_dir));
}

test "writeFile0644 refuses symlinked target" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim.txt" });
    defer gpa.free(victim);
    const link = try std.fs.path.join(gpa, &.{ dir_path, "link.txt" });
    defer gpa.free(link);
    try common.writeSmall(victim, "keep\n");

    var vb: [std.fs.max_path_bytes]u8 = undefined;
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(c.symlink(try common.toZ(&vb, victim), try common.toZ(&lb, link)) == 0);

    try testing.expectError(error.SymlinkRefused, writeFile0644(link, "replace\n"));
    const data = try common.readSmall(gpa, victim);
    defer gpa.free(data);
    try testing.expectEqualStrings("keep\n", data);

    _ = c.unlink(try common.toZ(&lb, link));
    _ = c.unlink(try common.toZ(&vb, victim));
}

test "writeFile0644 refuses symlinked parent" {
    const gpa = testing.allocator;
    const dir_path = try common.makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const outside = try std.fs.path.join(gpa, &.{ dir_path, "outside" });
    defer gpa.free(outside);
    try common.mkdirPath(outside);
    const link_parent = try std.fs.path.join(gpa, &.{ dir_path, "linked-parent" });
    defer gpa.free(link_parent);
    var ob: [std.fs.max_path_bytes]u8 = undefined;
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(c.symlink(try common.toZ(&ob, outside), try common.toZ(&lb, link_parent)) == 0);

    const target = try std.fs.path.join(gpa, &.{ link_parent, "payload.txt" });
    defer gpa.free(target);
    try testing.expectError(error.ParentSymlinkRefused, writeFile0644(target, "nope\n"));

    _ = c.unlink(try common.toZ(&lb, link_parent));
    _ = c.rmdir(try common.toZ(&ob, outside));
}

test "joinTokens collapses whitespace runs" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b c", joinTokens(a, "  a   b\tc  "));
    try testing.expectEqualStrings("", joinTokens(a, "   "));
}

test "isInitTarget covers init-only + alias sets" {
    try testing.expect(isInitTarget("pi"));
    try testing.expect(isInitTarget("claude-desktop"));
    try testing.expect(isInitTarget("cursor"));
    try testing.expect(isInitTarget("agents"));
    try testing.expect(!isInitTarget("nonexistent"));
}

test "uninstall settings-strip removes caveman hooks via settings.zig" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {"hooks": [{"type":"command","command":"\"node\" \"/x/caveman-activate.js\""}]}
        \\    ],
        \\    "UserPromptSubmit": [
        \\      {"hooks": [{"type":"command","command":"\"node\" \"/x/caveman-mode-tracker.js\""}]},
        \\      {"hooks": [{"type":"command","command":"other-tool"}]}
        \\    ]
        \\  },
        \\  "statusLine": {"type":"command","command":"bash /x/caveman-statusline.sh"}
        \\}
    ;
    var value = try settings.parseSettings(a, src);
    const removed = try settings.removeCavemanHooks(a, &value, "caveman");
    try testing.expectEqual(@as(usize, 2), removed);
    // statusLine strip mirrors uninstall().
    if (value.object.get("statusLine")) |sl| {
        const cmd = sl.object.get("command").?.string;
        if (std.mem.indexOf(u8, cmd, "caveman-statusline") != null) {
            _ = value.object.orderedRemove("statusLine");
        }
    }
    try testing.expect(value.object.get("statusLine") == null);
    // The non-caveman UserPromptSubmit entry survives.
    const ups = value.object.get("hooks").?.object.get("UserPromptSubmit").?.array;
    try testing.expectEqual(@as(usize, 1), ups.items.len);
}

test "pad right-fills to width" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ID           ", pad(a, "ID", 13));
    try testing.expectEqualStrings("toolong", pad(a, "toolong", 3)); // no truncation
}
