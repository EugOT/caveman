//! JSONC-tolerant settings.json read/write + defensive hook validation — Zig
//! 0.16 port of bin/lib/settings.js. Built as a MODULE (imported by the future
//! installer port in R4b) plus a tiny `caveman-settings` CLI surface used by the
//! differential check: it reads JSON on stdin, applies one transform, and prints
//! the result so the JS and Zig outputs can be diffed.
//!
//! Ported functions (parity with settings.js):
//!   - stripJsonComments(src)         string-aware comment + trailing-comma strip
//!   - validateHookFields(value)      drop malformed hook entries in place
//!   - hasCavemanHook(value, ev, marker)
//!   - addCommandHook(value, ev, opts)
//!   - removeCavemanHooks(value, marker)
//!   - rewriteLegacyManagedHookCommands(value, absoluteNode)
//!   - pruneOrphanedManagedHooks(value, configDir)
//!   - claudeConfigDir(gpa)
//!
//! The JSON model is std.json.Value backed by a caller-supplied arena so the
//! mutate-in-place semantics of the JS (which edits a parsed object graph) map
//! cleanly: we rebuild object/array nodes into the same arena. Pure libc C-ABI
//! for the filesystem probes (exists check), matching common.zig — no std.Io.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

// ── stripJsonComments ──────────────────────────────────────────────────────
// Hand-rolled state machine, byte-for-byte port of settings.js. Tracks string
// state + backslash escape so a comment-looking sequence inside a quoted string
// is left alone. Then a trailing-comma sweep over the comment-free output.
pub fn stripJsonComments(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    const n = src.len;
    var in_string = false;
    var string_char: u8 = 0;
    var in_line = false;
    var in_block = false;

    while (i < n) {
        const ch = src[i];
        const next: u8 = if (i + 1 < n) src[i + 1] else 0;
        if (in_line) {
            if (ch == '\n') {
                in_line = false;
                try out.append(gpa, ch);
            }
            i += 1;
            continue;
        }
        if (in_block) {
            if (ch == '*' and next == '/') {
                in_block = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if (in_string) {
            try out.append(gpa, ch);
            if (ch == '\\') {
                if (i + 1 < n) {
                    try out.append(gpa, src[i + 1]);
                    i += 2;
                    continue;
                }
            }
            if (ch == string_char) in_string = false;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_string = true;
            string_char = ch;
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        if (ch == '/' and next == '/') {
            in_line = true;
            i += 2;
            continue;
        }
        if (ch == '/' and next == '*') {
            in_block = true;
            i += 2;
            continue;
        }
        try out.append(gpa, ch);
        i += 1;
    }

    // Trailing-comma sweep: out.replace(/,(\s*[}\]])/g, '$1'). The JS regex
    // drops a comma immediately followed (across whitespace) by } or ]. Replicate
    // by emitting bytes, but when we hit ',' look ahead across whitespace for a
    // closer — if found, drop the comma (keep the whitespace + closer).
    const comment_free = out.items;
    var swept: std.ArrayList(u8) = .empty;
    errdefer swept.deinit(gpa);
    var j: usize = 0;
    while (j < comment_free.len) {
        const ch = comment_free[j];
        if (ch == ',') {
            var k = j + 1;
            while (k < comment_free.len and isJsonWs(comment_free[k])) k += 1;
            if (k < comment_free.len and (comment_free[k] == '}' or comment_free[k] == ']')) {
                // Drop the comma; whitespace + closer get emitted normally on
                // the following iterations.
                j += 1;
                continue;
            }
        }
        try swept.append(gpa, ch);
        j += 1;
    }
    out.deinit(gpa);
    return swept.toOwnedSlice(gpa);
}

fn isJsonWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c or ch == 0x0b;
}

// ── Value helpers (std.json.Value graph mutation) ──────────────────────────
// settings.js mutates a parsed JS object in place. We mirror that on
// std.json.Value: object fields live in an ObjectMap, arrays in ArrayList. All
// new allocations use the same arena the value graph lives in so freeing is the
// caller's single arena.deinit().

fn objGet(v: *std.json.Value, key: []const u8) ?*std.json.Value {
    return switch (v.*) {
        .object => |*o| o.getPtr(key),
        else => null,
    };
}

fn isObject(v: std.json.Value) bool {
    return v == .object;
}

fn isArray(v: std.json.Value) bool {
    return v == .array;
}

// ── validateHookFields ─────────────────────────────────────────────────────
// Mutate-to-valid. Drops malformed hook entries / events / the hooks tree.
pub fn validateHookFields(arena: std.mem.Allocator, settings: *std.json.Value) !void {
    if (settings.* != .object) return;
    const hooks_ptr = objGet(settings, "hooks") orelse return;
    if (hooks_ptr.* != .object) return;

    // Collect event keys first (we mutate the map while iterating).
    var ev_keys: std.ArrayList([]const u8) = .empty;
    defer ev_keys.deinit(arena);
    {
        var it = hooks_ptr.object.iterator();
        while (it.next()) |entry| try ev_keys.append(arena, entry.key_ptr.*);
    }

    for (ev_keys.items) |ev| {
        const arr_ptr = hooks_ptr.object.getPtr(ev).?;
        if (arr_ptr.* != .array) {
            _ = hooks_ptr.object.orderedRemove(ev);
            continue;
        }
        var kept: std.json.Array = .init(arena);
        for (arr_ptr.array.items) |entry_val| {
            var entry = entry_val;
            if (entry != .object) continue;
            const inner_ptr = objGet(&entry, "hooks") orelse continue;
            if (inner_ptr.* != .array) continue;
            var kept_inner: std.json.Array = .init(arena);
            for (inner_ptr.array.items) |h| {
                if (h != .object) continue;
                if (hookEntryValid(h)) try kept_inner.append(h);
            }
            if (kept_inner.items.len == 0) continue;
            inner_ptr.array = kept_inner;
            try kept.append(entry);
        }
        if (kept.items.len == 0) {
            _ = hooks_ptr.object.orderedRemove(ev);
        } else {
            arr_ptr.array = kept;
        }
    }

    if (hooks_ptr.object.count() == 0) {
        _ = settings.object.orderedRemove("hooks");
    }
}

fn hookEntryValid(h: std.json.Value) bool {
    if (h != .object) return false;
    const t = h.object.get("type") orelse return false;
    const ts = switch (t) {
        .string => |s| s,
        else => return false,
    };
    if (std.mem.eql(u8, ts, "command")) {
        const cmd = h.object.get("command") orelse return false;
        return switch (cmd) {
            .string => |s| s.len > 0,
            else => false,
        };
    }
    if (std.mem.eql(u8, ts, "agent")) {
        const p = h.object.get("prompt") orelse return false;
        return switch (p) {
            .string => |s| s.len > 0,
            else => false,
        };
    }
    return false;
}

// ── hasCavemanHook ─────────────────────────────────────────────────────────
pub fn hasCavemanHook(settings: *std.json.Value, event: []const u8, marker: []const u8) bool {
    if (settings.* != .object) return false;
    const hooks = settings.object.get("hooks") orelse return false;
    if (hooks != .object) return false;
    const arr = hooks.object.get(event) orelse return false;
    if (arr != .array) return false;
    for (arr.array.items) |entry| {
        if (entry != .object) continue;
        const inner = entry.object.get("hooks") orelse continue;
        if (inner != .array) continue;
        for (inner.array.items) |h| {
            if (h != .object) continue;
            const cmd = h.object.get("command") orelse continue;
            switch (cmd) {
                .string => |s| if (std.mem.indexOf(u8, s, marker) != null) return true,
                else => {},
            }
        }
    }
    return false;
}

pub const AddHookOpts = struct {
    command: []const u8,
    marker: ?[]const u8 = null,
    timeout: ?i64 = null,
    status_message: ?[]const u8 = null,
};

// ── addCommandHook ─────────────────────────────────────────────────────────
// Idempotent push. Returns true if added, false if marker already present.
pub fn addCommandHook(arena: std.mem.Allocator, settings: *std.json.Value, event: []const u8, opts: AddHookOpts) !bool {
    if (settings.* != .object) return false;
    if (settings.object.get("hooks") == null or settings.object.get("hooks").? != .object) {
        try settings.object.put("hooks", .{ .object = std.json.ObjectMap.init(arena) });
    }
    const hooks_ptr = settings.object.getPtr("hooks").?;
    if (hooks_ptr.object.get(event) == null or hooks_ptr.object.get(event).? != .array) {
        try hooks_ptr.object.put(event, .{ .array = std.json.Array.init(arena) });
    }
    const marker = opts.marker orelse opts.command;
    if (hasCavemanHook(settings, event, marker)) return false;

    var hook = std.json.ObjectMap.init(arena);
    try hook.put("type", .{ .string = "command" });
    try hook.put("command", .{ .string = opts.command });
    if (opts.timeout) |t| try hook.put("timeout", .{ .integer = t });
    if (opts.status_message) |m| try hook.put("statusMessage", .{ .string = m });

    var inner = std.json.Array.init(arena);
    try inner.append(.{ .object = hook });
    var wrapper = std.json.ObjectMap.init(arena);
    try wrapper.put("hooks", .{ .array = inner });

    const arr_ptr = hooks_ptr.object.getPtr(event).?;
    try arr_ptr.array.append(.{ .object = wrapper });
    return true;
}

// ── addCavemanHooks (full standalone-install merge) ────────────────────────
// Wire the three managed Zig-binary hooks + statusline into `settings`, all
// idempotent. Mirrors the merge that bin/install.js / install.zig perform, but
// pointed at the prebuilt Zig binaries (no node, no bash wrapper): the binaries
// are native executables invoked directly by absolute path.
//
//   SessionStart    → "<hooks_dir>/caveman-activate"
//   UserPromptSubmit→ "<hooks_dir>/caveman-hook"
//   statusLine      → "<hooks_dir>/caveman-statusline"
//
// Returns how the statusline ended up so the caller can report it:
//   .configured  — we added the caveman statusLine (none was present)
//   .already     — a caveman statusLine was already present
//   .skipped     — a non-caveman statusLine exists; left untouched
pub const StatusLineResult = enum { configured, already, skipped };

pub fn addCavemanHooks(arena: std.mem.Allocator, settings: *std.json.Value, hooks_dir: []const u8) !StatusLineResult {
    if (settings.* != .object) {
        settings.* = .{ .object = std.json.ObjectMap.init(arena) };
    }

    const activate = try std.fs.path.join(arena, &.{ hooks_dir, "caveman-activate" });
    const hook = try std.fs.path.join(arena, &.{ hooks_dir, "caveman-hook" });
    const statusline = try std.fs.path.join(arena, &.{ hooks_dir, "caveman-statusline" });

    // The Zig hook binaries are native executables — the settings.json command is
    // just the quoted absolute path, no interpreter prefix. Marker keys off the
    // basename so the entry is recognized regardless of how the path was quoted.
    const activate_cmd = try std.fmt.allocPrint(arena, "\"{s}\"", .{activate});
    _ = try addCommandHook(arena, settings, "SessionStart", .{
        .command = activate_cmd,
        .marker = "caveman-activate",
        .timeout = 5,
        .status_message = "Loading caveman mode...",
    });

    const hook_cmd = try std.fmt.allocPrint(arena, "\"{s}\"", .{hook});
    _ = try addCommandHook(arena, settings, "UserPromptSubmit", .{
        .command = hook_cmd,
        .marker = "caveman-hook",
        .timeout = 5,
        .status_message = "Tracking caveman mode...",
    });

    // statusLine lives outside hooks. Add only if absent; never clobber a
    // user-defined statusline.
    const sl_cmd = try std.fmt.allocPrint(arena, "\"{s}\"", .{statusline});
    var result: StatusLineResult = .skipped;
    if (settings.object.get("statusLine") == null) {
        var slo = std.json.ObjectMap.init(arena);
        try slo.put("type", .{ .string = "command" });
        try slo.put("command", .{ .string = sl_cmd });
        try settings.object.put("statusLine", .{ .object = slo });
        result = .configured;
    } else {
        const sl_val = settings.object.get("statusLine").?;
        const existing = switch (sl_val) {
            .string => |s| s,
            .object => |o| if (o.get("command")) |cv| (if (cv == .string) cv.string else "") else "",
            else => "",
        };
        if (std.mem.indexOf(u8, existing, "caveman-statusline") != null) {
            result = .already;
        } else {
            result = .skipped;
        }
    }

    try validateHookFields(arena, settings);
    return result;
}

// ── removeCavemanHooks ─────────────────────────────────────────────────────
// Strip every entry whose any hook command mentions `marker`. Returns count.
pub fn removeCavemanHooks(arena: std.mem.Allocator, settings: *std.json.Value, marker: []const u8) !usize {
    if (settings.* != .object) return 0;
    if (settings.object.get("hooks") == null) return 0;
    try validateHookFields(arena, settings);
    if (settings.object.get("hooks") == null) return 0;
    const hooks_ptr = settings.object.getPtr("hooks").?;
    if (hooks_ptr.* != .object) return 0;

    var removed: usize = 0;
    var ev_keys: std.ArrayList([]const u8) = .empty;
    defer ev_keys.deinit(arena);
    {
        var it = hooks_ptr.object.iterator();
        while (it.next()) |entry| try ev_keys.append(arena, entry.key_ptr.*);
    }
    for (ev_keys.items) |ev| {
        const arr_ptr = hooks_ptr.object.getPtr(ev).?;
        if (arr_ptr.* != .array) {
            _ = hooks_ptr.object.orderedRemove(ev);
            continue;
        }
        const before = arr_ptr.array.items.len;
        var kept: std.json.Array = .init(arena);
        for (arr_ptr.array.items) |entry| {
            if (entryMentionsMarker(entry, marker)) continue;
            try kept.append(entry);
        }
        removed += before - kept.items.len;
        if (kept.items.len == 0) {
            _ = hooks_ptr.object.orderedRemove(ev);
        } else {
            arr_ptr.array = kept;
        }
    }
    if (hooks_ptr.object.count() == 0) {
        _ = settings.object.orderedRemove("hooks");
    }
    return removed;
}

// ── removeCavemanStatusLine ────────────────────────────────────────────────
// Drop a managed statusLine (string or {command}) whose command references
// "caveman-statusline". Mirrors the statusLine strip install.zig's uninstall
// performs alongside removeCavemanHooks. Returns true if removed.
pub fn removeCavemanStatusLine(settings: *std.json.Value) bool {
    if (settings.* != .object) return false;
    const sl = settings.object.get("statusLine") orelse return false;
    const cmd = switch (sl) {
        .string => |s| s,
        .object => |o| if (o.get("command")) |cv| (if (cv == .string) cv.string else "") else "",
        else => "",
    };
    if (std.mem.indexOf(u8, cmd, "caveman-statusline") != null) {
        _ = settings.object.orderedRemove("statusLine");
        return true;
    }
    return false;
}

// JS keeps an entry whose hooks array is absent/malformed (filter returns true),
// drops it only when SOME hook command includes the marker.
fn entryMentionsMarker(entry: std.json.Value, marker: []const u8) bool {
    if (entry != .object) return false;
    const inner = entry.object.get("hooks") orelse return false;
    if (inner != .array) return false;
    for (inner.array.items) |h| {
        if (h != .object) continue;
        const cmd = h.object.get("command") orelse continue;
        switch (cmd) {
            .string => |s| if (std.mem.indexOf(u8, s, marker) != null) return true,
            else => {},
        }
    }
    return false;
}

pub const MANAGED_HOOK_BASENAMES = [_][]const u8{
    // Legacy JS/shell hook filenames (pre-R6.3 standalone installs).
    "caveman-activate.js",
    "caveman-mode-tracker.js",
    "caveman-stats.js",
    "caveman-statusline.sh",
    "caveman-statusline.ps1",
    // R6.3 pure-Zig hook binaries (native executables, no extension).
    "caveman-activate",
    "caveman-hook",
    "caveman-stats",
    "caveman-statusline",
};

fn isManagedBasename(name: []const u8) bool {
    for (MANAGED_HOOK_BASENAMES) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

// ── rewriteLegacyManagedHookCommands ───────────────────────────────────────
// Bare `node <script>` (quoted or not) where basename is managed → rewrite to
// `"<absoluteNode>" "<script>"`. Returns count rewritten.
pub fn rewriteLegacyManagedHookCommands(arena: std.mem.Allocator, settings: *std.json.Value, absolute_node: []const u8) !usize {
    if (settings.* != .object) return 0;
    if (absolute_node.len == 0) return 0;
    const hooks = settings.object.get("hooks") orelse return 0;
    if (hooks != .object) return 0;
    const hooks_ptr = settings.object.getPtr("hooks").?;

    var rewritten: usize = 0;
    var it = hooks_ptr.object.iterator();
    while (it.next()) |entry| {
        const arr = entry.value_ptr;
        if (arr.* != .array) continue;
        for (arr.array.items) |hentry| {
            if (hentry != .object) continue;
            const inner = hentry.object.get("hooks") orelse continue;
            if (inner != .array) continue;
            for (inner.array.items) |*h| {
                if (h.* != .object) continue;
                const cmd_ptr = h.object.getPtr("command") orelse continue;
                const cmd = switch (cmd_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                const script = parseBareNode(cmd) orelse continue;
                const basename = std.fs.path.basename(script);
                if (!isManagedBasename(basename)) continue;
                const new_cmd = try std.fmt.allocPrint(arena, "\"{s}\" \"{s}\"", .{ absolute_node, script });
                cmd_ptr.* = .{ .string = new_cmd };
                rewritten += 1;
            }
        }
    }
    return rewritten;
}

// Port of /^node\s+("([^"]+)"|'([^']+)'|(\S+))\s*$/ — returns the script path
// (unquoted) or null. Requires the command to be exactly `node <one-token>`
// optionally with surrounding/trailing whitespace.
fn parseBareNode(cmd: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, cmd, "node")) return null;
    if (cmd.len < 5) return null;
    if (!isWs(cmd[4])) return null;
    var i: usize = 4;
    while (i < cmd.len and isWs(cmd[i])) i += 1;
    if (i >= cmd.len) return null;

    var script: []const u8 = undefined;
    var rest_start: usize = undefined;
    if (cmd[i] == '"') {
        const end = std.mem.indexOfScalarPos(u8, cmd, i + 1, '"') orelse return null;
        script = cmd[i + 1 .. end];
        rest_start = end + 1;
    } else if (cmd[i] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, cmd, i + 1, '\'') orelse return null;
        script = cmd[i + 1 .. end];
        rest_start = end + 1;
    } else {
        // \S+ — run of non-whitespace.
        var end = i;
        while (end < cmd.len and !isWs(cmd[end])) end += 1;
        script = cmd[i..end];
        rest_start = end;
    }
    // Trailing must be only whitespace (regex anchored with $ and \s*).
    var k = rest_start;
    while (k < cmd.len) : (k += 1) {
        if (!isWs(cmd[k])) return null;
    }
    return script;
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c or ch == 0x0b;
}

// ── pruneOrphanedManagedHooks ──────────────────────────────────────────────
// Drop managed hook entries whose target script is missing on disk. Also drops
// an orphaned managed statusLine. Returns count removed.
pub fn pruneOrphanedManagedHooks(io: std.Io, arena: std.mem.Allocator, settings: *std.json.Value, config_dir: ?[]const u8) !usize {
    if (settings.* != .object) return 0;
    const base_dir = config_dir orelse try claudeConfigDir(arena);
    var removed: usize = 0;

    if (settings.object.get("hooks")) |hooks| {
        if (hooks == .object) try validateHookFields(arena, settings);
    }
    if (settings.object.get("hooks")) |hooks| {
        if (hooks == .object) {
            const hooks_ptr = settings.object.getPtr("hooks").?;
            var ev_keys: std.ArrayList([]const u8) = .empty;
            defer ev_keys.deinit(arena);
            {
                var it = hooks_ptr.object.iterator();
                while (it.next()) |entry| try ev_keys.append(arena, entry.key_ptr.*);
            }
            for (ev_keys.items) |ev| {
                const arr_ptr = hooks_ptr.object.getPtr(ev).?;
                if (arr_ptr.* != .array) {
                    _ = hooks_ptr.object.orderedRemove(ev);
                    continue;
                }
                const before = arr_ptr.array.items.len;
                var kept: std.json.Array = .init(arena);
                for (arr_ptr.array.items) |entry| {
                    if (entryTargetMissing(io, arena, entry, base_dir)) continue;
                    try kept.append(entry);
                }
                removed += before - kept.items.len;
                if (kept.items.len == 0) {
                    _ = hooks_ptr.object.orderedRemove(ev);
                } else {
                    arr_ptr.array = kept;
                }
            }
            if (hooks_ptr.object.count() == 0) {
                _ = settings.object.orderedRemove("hooks");
            }
        }
    }

    // statusLine lives outside hooks.
    if (settings.object.get("statusLine")) |sl| {
        if (sl == .object) {
            if (sl.object.get("command")) |cmd| {
                switch (cmd) {
                    .string => |s| {
                        if (commandTargetMissing(io, arena, s, base_dir)) {
                            _ = settings.object.orderedRemove("statusLine");
                            removed += 1;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    return removed;
}

// An entry is dropped iff some hook's command is a managed target that is
// missing. JS: entry kept (true) when entry malformed; dropped (false from
// filter perspective → we return true="missing/drop") when some command misses.
fn entryTargetMissing(io: std.Io, arena: std.mem.Allocator, entry: std.json.Value, base_dir: []const u8) bool {
    if (entry != .object) return false;
    const inner = entry.object.get("hooks") orelse return false;
    if (inner != .array) return false;
    for (inner.array.items) |h| {
        if (h != .object) continue;
        const cmd = h.object.get("command") orelse continue;
        switch (cmd) {
            .string => |s| if (commandTargetMissing(io, arena, s, base_dir)) return true,
            else => {},
        }
    }
    return false;
}

// Port of targetMissing(command): tokenize honoring quotes; first token whose
// basename is an exact managed name decides — resolve (abs or under base_dir),
// return true if absent. No managed token → false.
fn commandTargetMissing(io: std.Io, arena: std.mem.Allocator, command: []const u8, base_dir: []const u8) bool {
    var tokens = tokenizeCommand(arena, command) catch return false;
    defer tokens.deinit(arena);
    for (tokens.items) |tok| {
        if (tok.len == 0) continue;
        if (!isManagedBasename(std.fs.path.basename(tok))) continue;
        const script_path = if (std.fs.path.isAbsolute(tok))
            tok
        else
            std.fs.path.join(arena, &.{ base_dir, tok }) catch return false;
        return !pathExists(io, script_path);
    }
    return false;
}

// Port of the JS regex tokenizer /"([^"]*)"|'([^']*)'|(\S+)/g — quoted spans or
// runs of non-whitespace. Returns the captured contents (quotes stripped).
fn tokenizeCommand(arena: std.mem.Allocator, command: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < command.len) {
        const ch = command[i];
        if (ch == '"') {
            const end = std.mem.indexOfScalarPos(u8, command, i + 1, '"') orelse {
                // Unterminated quote: regex would not match this as a quoted
                // group; the bare `"` then matches \S+ runs. Mirror by taking
                // the rest as a non-ws run from here.
                var e = i;
                while (e < command.len and !isWs(command[e])) e += 1;
                try out.append(arena, command[i..e]);
                i = e;
                continue;
            };
            try out.append(arena, command[i + 1 .. end]);
            i = end + 1;
            continue;
        }
        if (ch == '\'') {
            const end = std.mem.indexOfScalarPos(u8, command, i + 1, '\'') orelse {
                var e = i;
                while (e < command.len and !isWs(command[e])) e += 1;
                try out.append(arena, command[i..e]);
                i = e;
                continue;
            };
            try out.append(arena, command[i + 1 .. end]);
            i = end + 1;
            continue;
        }
        if (isWs(ch)) {
            i += 1;
            continue;
        }
        // \S+ run — but stop at a quote boundary like the regex alternation does.
        var e = i;
        while (e < command.len and !isWs(command[e]) and command[e] != '"' and command[e] != '\'') e += 1;
        try out.append(arena, command[i..e]);
        i = e;
    }
    return out;
}

// std.Io existence probe. Mirrors fs.existsSync: statFile FOLLOWING symlinks so a
// managed hook target reachable via a symlink still counts as present, matching
// Node's fs.existsSync. std.Io (R6a) so the binary cross-compiles.
fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

// ── claudeConfigDir ────────────────────────────────────────────────────────
pub fn claudeConfigDir(gpa: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("CLAUDE_CONFIG_DIR")) |p| {
        return gpa.dupe(u8, std.mem.sliceTo(p, 0));
    }
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ std.mem.sliceTo(home, 0), ".claude" });
}

// ── readSettings / writeSettings ───────────────────────────────────────────
// Parse a settings file: strict JSON first, JSONC fallback. Returns a Parsed
// owning the arena. Caller deinits. Missing/empty file → empty object value.
pub const ParseError = error{ ReadFailed, NotJson } || std.mem.Allocator.Error;

/// Parse raw settings text into a std.json.Value using `arena`. Tries strict
/// JSON, then comment-stripped JSONC. Empty/blank → empty object.
pub fn parseSettings(arena: std.mem.Allocator, raw: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .object = std.json.ObjectMap.init(arena) };
    }
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{})) |v| {
        return v;
    } else |_| {}
    const stripped = try stripJsonComments(arena, raw);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch error.NotJson;
}

/// Serialize a value to a 2-space-indented JSON string + trailing newline.
pub fn stringifySettings(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

// ── CLI surface (caveman-settings) ─────────────────────────────────────────
// Minimal stdin→stdout transform driver used by the differential harness.
//   caveman-settings strip                  → stripJsonComments(stdin)
//   caveman-settings validate               → parse, validateHookFields, print
//   caveman-settings prune [configDir]      → parse, pruneOrphanedManagedHooks, print
//   caveman-settings remove [marker]        → parse, removeCavemanHooks, print
//   caveman-settings rewrite <absNode>      → parse, rewriteLegacyManagedHookCommands, print
//   caveman-settings add <hooksDir>         → parse, wire Zig hook binaries +
//                                             statusline (idempotent), print.
//                                             statusline state → exit code:
//                                             0 configured, 0 already, 0 skipped;
//                                             a one-line note on stderr.
// For mutating ops the printed JSON is the post-mutation document.
// 0.16 entry shape: the no-alloc POSIX arg iterator (init, not std.Io) keeps us
// on the libc C-ABI surface like the rest of the hook tree (stats.zig).
pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Construct the std.Io backend once; thread it down to the FS-touching prune
    // path. This module has no common.zig dependency, so construct directly.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Collect argv (after argv0) into a slice so we can index positionally.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    {
        var it = init.args.iterate();
        defer it.deinit();
        _ = it.skip(); // argv0
        // dupe into the arena — iterator storage is freed at it.deinit().
        while (it.next()) |a| argv.append(arena, arena.dupe(u8, a) catch continue) catch {};
    }

    if (argv.items.len < 1) {
        writeStderr("usage: caveman-settings <strip|validate|prune|remove|rewrite|add> [arg]\n");
        std.process.exit(2);
    }
    const cmd = argv.items[0];

    const input = readAllStdin(arena) catch "";

    if (std.mem.eql(u8, cmd, "strip")) {
        const out = try stripJsonComments(arena, input);
        writeStdout(out);
        return;
    }

    var value = parseSettings(arena, input) catch {
        writeStderr("caveman-settings: input is not valid JSON or JSONC\n");
        std.process.exit(1);
    };

    if (std.mem.eql(u8, cmd, "validate")) {
        try validateHookFields(arena, &value);
    } else if (std.mem.eql(u8, cmd, "prune")) {
        const dir: ?[]const u8 = if (argv.items.len >= 2) argv.items[1] else null;
        _ = try pruneOrphanedManagedHooks(io, arena, &value, dir);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        const marker: []const u8 = if (argv.items.len >= 2) argv.items[1] else "caveman";
        _ = try removeCavemanHooks(arena, &value, marker);
        // Also drop a managed caveman statusLine — install.zig's uninstall path
        // strips it alongside the hooks, so the CLI surface must too for the
        // shell uninstaller to reach full parity.
        _ = removeCavemanStatusLine(&value);
    } else if (std.mem.eql(u8, cmd, "rewrite")) {
        if (argv.items.len < 2) {
            writeStderr("caveman-settings rewrite requires <absoluteNode>\n");
            std.process.exit(2);
        }
        _ = try rewriteLegacyManagedHookCommands(arena, &value, argv.items[1]);
    } else if (std.mem.eql(u8, cmd, "add")) {
        if (argv.items.len < 2) {
            writeStderr("caveman-settings add requires <hooksDir>\n");
            std.process.exit(2);
        }
        const sl = try addCavemanHooks(arena, &value, argv.items[1]);
        // Report statusline state on stderr — stdout must stay pure JSON so the
        // installer can capture it. The shell echoes these to the user.
        switch (sl) {
            .configured => writeStderr("  statusline badge configured.\n"),
            .already => writeStderr("  statusline badge already configured.\n"),
            .skipped => writeStderr("  note: existing statusline detected — caveman badge NOT added.\n"),
        }
    } else {
        writeStderr("caveman-settings: unknown command\n");
        std.process.exit(2);
    }

    const out = try stringifySettings(arena, value);
    writeStdout(out);
}

fn readAllStdin(gpa: std.mem.Allocator) ![]u8 {
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

fn writeStderr(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(2, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────
// Mirror tests/installer/unit.settings.test.mjs.

const testing = std.testing;

fn parse(arena: std.mem.Allocator, raw: []const u8) !std.json.Value {
    return parseSettings(arena, raw);
}

test "stripJsonComments strips // line comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try stripJsonComments(arena.allocator(), "{\"a\":1}// trail");
    try testing.expectEqualStrings("{\"a\":1}", std.mem.trim(u8, out, " \t\r\n"));
}

test "stripJsonComments strips block comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try stripJsonComments(arena.allocator(), "{/* leading */\"a\":1/* mid */, \"b\":2}");
    try testing.expect(std.mem.indexOf(u8, out, "\"a\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"b\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "leading") == null);
}

test "stripJsonComments leaves comment-looking sequences inside strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try stripJsonComments(arena.allocator(), "{\"url\":\"http://example.com//path\"}");
    try testing.expectEqualStrings("{\"url\":\"http://example.com//path\"}", out);
}

test "stripJsonComments strips trailing commas (parses clean)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try stripJsonComments(a, "{\"a\":[1,2,3,],}");
    // Must be valid JSON now.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try testing.expect(v == .object);
}

test "parseSettings handles plain JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try parse(arena.allocator(), "{\"theme\":\"dark\"}");
    try testing.expectEqualStrings("dark", v.object.get("theme").?.string);
}

test "parseSettings handles JSONC comments + trailing commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try parse(arena.allocator(),
        \\// my settings
        \\{
        \\  "theme": "dark", /* mode */
        \\  "hooks": {},
        \\}
    );
    try testing.expectEqualStrings("dark", v.object.get("theme").?.string);
    try testing.expect(v.object.get("hooks").? == .object);
}

test "parseSettings empty → empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "   \n  ");
    try testing.expect(v == .object);
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

test "parseSettings garbage → NotJson" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotJson, parse(arena.allocator(), "this is not json at all {{{"));
}

test "validateHookFields drops malformed command hook (missing command)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command"},{"type":"command","command":"good"}]}]}}
    );
    try validateHookFields(a, &v);
    const inner = v.object.get("hooks").?.object.get("SessionStart").?.array.items[0].object.get("hooks").?.array;
    try testing.expectEqual(@as(usize, 1), inner.items.len);
    try testing.expectEqualStrings("good", inner.items[0].object.get("command").?.string);
}

test "validateHookFields drops malformed agent hook (missing prompt)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"agent\"}]}]}}");
    try validateHookFields(a, &v);
    try testing.expect(v.object.get("hooks") == null);
}

test "validateHookFields drops empty events and empty hooks parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{\"hooks\":{\"SessionStart\":[],\"UserPromptSubmit\":[{\"hooks\":[]}]}}");
    try validateHookFields(a, &v);
    try testing.expect(v.object.get("hooks") == null);
}

test "addCommandHook is idempotent on substring marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{}");
    const r1 = try addCommandHook(a, &v, "SessionStart", .{ .command = "/abs/path/caveman-activate.js", .marker = "caveman-activate" });
    const r2 = try addCommandHook(a, &v, "SessionStart", .{ .command = "/different/abs/path/caveman-activate.js", .marker = "caveman-activate" });
    try testing.expect(r1);
    try testing.expect(!r2);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("SessionStart").?.array.items.len);
}

test "addCavemanHooks wires the three Zig hook binaries + statusline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{}");
    const sl = try addCavemanHooks(a, &v, "/home/u/.claude/hooks");
    try testing.expectEqual(StatusLineResult.configured, sl);

    // SessionStart → caveman-activate (quoted absolute path, no interpreter).
    const ss = v.object.get("hooks").?.object.get("SessionStart").?.array;
    try testing.expectEqual(@as(usize, 1), ss.items.len);
    const ss_cmd = ss.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("\"/home/u/.claude/hooks/caveman-activate\"", ss_cmd);

    // UserPromptSubmit → caveman-hook.
    const ups = v.object.get("hooks").?.object.get("UserPromptSubmit").?.array;
    const ups_cmd = ups.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("\"/home/u/.claude/hooks/caveman-hook\"", ups_cmd);

    // statusLine → caveman-statusline.
    const slc = v.object.get("statusLine").?.object.get("command").?.string;
    try testing.expectEqualStrings("\"/home/u/.claude/hooks/caveman-statusline\"", slc);
}

test "addCavemanHooks is idempotent (re-add adds nothing)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{}");
    _ = try addCavemanHooks(a, &v, "/h");
    const sl2 = try addCavemanHooks(a, &v, "/h");
    try testing.expectEqual(StatusLineResult.already, sl2);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("SessionStart").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("UserPromptSubmit").?.array.items.len);
}

test "addCavemanHooks never clobbers a non-caveman statusLine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{\"statusLine\":{\"type\":\"command\",\"command\":\"my-prompt.sh\"}}");
    const sl = try addCavemanHooks(a, &v, "/h");
    try testing.expectEqual(StatusLineResult.skipped, sl);
    try testing.expectEqualStrings("my-prompt.sh", v.object.get("statusLine").?.object.get("command").?.string);
}

test "hasCavemanHook detects via substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node /x/caveman-activate.js"}]}]}}
    );
    try testing.expect(hasCavemanHook(&v, "SessionStart", "caveman-activate"));
    try testing.expect(!hasCavemanHook(&v, "SessionStart", "gsd"));
    try testing.expect(!hasCavemanHook(&v, "UserPromptSubmit", "caveman"));
}

test "removeCavemanHooks tolerates malformed event values without throwing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a, "{\"hooks\":{\"SessionStart\":\"oops\",\"UserPromptSubmit\":{\"not\":\"an array\"}}}");
    const removed = try removeCavemanHooks(a, &v, "caveman");
    try testing.expectEqual(@as(usize, 0), removed);
    try testing.expect(v.object.get("hooks") == null);
}

test "removeCavemanHooks strips by marker and cleans empties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"caveman-x"}]},{"hooks":[{"type":"command","command":"other"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"caveman-y"}]}]}}
    );
    const removed = try removeCavemanHooks(a, &v, "caveman");
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("SessionStart").?.array.items.len);
    try testing.expect(v.object.get("hooks").?.object.get("UserPromptSubmit") == null);
}

test "removeCavemanStatusLine drops managed statusLine, keeps user one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Managed (Zig binary path) → removed.
    var v1 = try parse(a, "{\"statusLine\":{\"type\":\"command\",\"command\":\"\\\"/h/caveman-statusline\\\"\"}}");
    try testing.expect(removeCavemanStatusLine(&v1));
    try testing.expect(v1.object.get("statusLine") == null);
    // Legacy shell path → also removed (substring match).
    var v2 = try parse(a, "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash /h/caveman-statusline.sh\"}}");
    try testing.expect(removeCavemanStatusLine(&v2));
    // User statusline → preserved.
    var v3 = try parse(a, "{\"statusLine\":{\"type\":\"command\",\"command\":\"my-prompt.sh\"}}");
    try testing.expect(!removeCavemanStatusLine(&v3));
    try testing.expect(v3.object.get("statusLine") != null);
}

test "rewriteLegacyManagedHookCommands rewrites bare-node managed scripts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node /abs/hooks/caveman-activate.js"},{"type":"command","command":"node /abs/hooks/some-user-hook.js"}]}]}}
    );
    const n = try rewriteLegacyManagedHookCommands(a, &v, "/usr/local/bin/node");
    try testing.expectEqual(@as(usize, 1), n);
    const inner = v.object.get("hooks").?.object.get("SessionStart").?.array.items[0].object.get("hooks").?.array;
    try testing.expectEqualStrings("\"/usr/local/bin/node\" \"/abs/hooks/caveman-activate.js\"", inner.items[0].object.get("command").?.string);
    try testing.expectEqualStrings("node /abs/hooks/some-user-hook.js", inner.items[1].object.get("command").?.string);
}

test "rewriteLegacyManagedHookCommands ignores already-absolute node commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"/usr/local/bin/node\" \"/abs/hooks/caveman-activate.js\""}]}]}}
    );
    const n = try rewriteLegacyManagedHookCommands(a, &v, "/somewhere/else/node");
    try testing.expectEqual(@as(usize, 0), n);
}

test "pruneOrphanedManagedHooks removes missing absolute-node managed hook" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"/opt/node/bin/node\" \"/no/such/dir/caveman-activate.js\""}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("hooks") == null);
}

test "pruneOrphanedManagedHooks removes orphan bare-node managed hook" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"node /no/such/dir/caveman-mode-tracker.js"}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("hooks") == null);
}

test "pruneOrphanedManagedHooks keeps managed hook whose target exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();

    // Create the script so its target exists. Build the fixture through std.Io
    // (Dir.createDir / Dir.createFile + writePositionalAll) — the same portable
    // surface the code under test uses — instead of raw libc mkdir/open/write.
    const base = std.c.getenv("TMPDIR");
    const base_dir = if (base) |p| std.mem.sliceTo(p, 0) else "/tmp";
    const dir = try std.fmt.allocPrint(a, "{s}/cm-prune-zig.{d}", .{ base_dir, c.getpid() });
    std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700)) catch {};
    const script = try std.fs.path.join(a, &.{ dir, "caveman-activate.js" });
    {
        std.Io.Dir.cwd().deleteFile(io, script) catch {};
        if (std.Io.Dir.cwd().createFile(io, script, .{ .exclusive = true, .permissions = .fromMode(0o600) })) |f_const| {
            var f = f_const;
            defer f.close(io);
            f.writePositionalAll(io, "x", 0) catch {};
        } else |_| {}
    }

    const json = try std.fmt.allocPrint(a,
        \\{{"hooks":{{"SessionStart":[{{"hooks":[{{"type":"command","command":"\"/opt/node/bin/node\" \"{s}\""}}]}}]}}}}
    , .{script});
    var v = try parse(a, json);
    const removed = try pruneOrphanedManagedHooks(io, a, &v, dir);
    try testing.expectEqual(@as(usize, 0), removed);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("SessionStart").?.array.items.len);
}

test "pruneOrphanedManagedHooks leaves non-managed hooks alone even if missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node /no/such/dir/some-user-hook.js"},{"type":"command","command":"[ -n \"$SUPERSET_HOME_DIR\" ] && \"$SUPERSET_HOME_DIR/hooks/notify.sh\" || true"}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 0), removed);
    try testing.expectEqual(@as(usize, 2), v.object.get("hooks").?.object.get("SessionStart").?.array.items[0].object.get("hooks").?.array.items.len);
}

test "pruneOrphanedManagedHooks resolves relative target against configDir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node hooks/caveman-activate.js"}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_rel_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("hooks") == null);
}

test "pruneOrphanedManagedHooks does NOT match user script merely containing managed basename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node /no/such/dir/mycaveman-activate.js"}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 0), removed);
    try testing.expectEqual(@as(usize, 1), v.object.get("hooks").?.object.get("SessionStart").?.array.items[0].object.get("hooks").?.array.items.len);
}

test "pruneOrphanedManagedHooks handles quoted paths containing spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"/opt/node/bin/node\" \"/no such dir/caveman-activate.js\""}]}]}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("hooks") == null);
}

test "pruneOrphanedManagedHooks drops orphaned managed statusLine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"statusLine":{"type":"command","command":"bash /no/such/dir/caveman-statusline.sh"}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("statusLine") == null);
}

test "pruneOrphanedManagedHooks drops orphaned managed PowerShell statusLine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try parse(a,
        \\{"statusLine":{"type":"command","command":"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"/no/such/dir/caveman-statusline.ps1\""}}
    );
    var th_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer th_io.deinit();
    const io = th_io.io();
    const removed = try pruneOrphanedManagedHooks(io, a, &v, "/tmp/__cm_cfg_missing");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(v.object.get("statusLine") == null);
}

test "claudeConfigDir honors CLAUDE_CONFIG_DIR env" {
    const a = testing.allocator;
    const old = std.c.getenv("CLAUDE_CONFIG_DIR");
    _ = setenv("CLAUDE_CONFIG_DIR", "/tmp/__cm_test_cfg", 1);
    defer {
        if (old) |o| {
            _ = setenv("CLAUDE_CONFIG_DIR", o, 1);
        } else {
            _ = unsetenv("CLAUDE_CONFIG_DIR");
        }
    }
    const dir = try claudeConfigDir(a);
    defer a.free(dir);
    try testing.expectEqualStrings("/tmp/__cm_test_cfg", dir);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
