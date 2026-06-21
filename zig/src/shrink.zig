//! caveman-shrink — MCP middleware proxy, Zig 0.16 (libc C-ABI).
//!
//! Port of src/mcp-servers/caveman-shrink/{index.js,compress.js,spawn-options.js}.
//!
//! A stdio JSON-RPC PROXY: spawns an upstream MCP server (argv[1..]),
//! line-buffers stdin->upstream and upstream->stdout, and on the
//! upstream->client direction compresses prose `description` fields in
//! tools/list (and prompts/resources/resourceTemplates list) responses using
//! the same boundaries as caveman-compress (preserve code, URLs, paths,
//! identifiers). Everything else passes through byte-for-byte.
//!
//! Written against the stable libc C ABI (std.c + a few extern decls) rather
//! than std.process.Child — Child now takes a std.Io parameter in this 0.16-dev
//! build, and the rest of this codebase (common.zig) deliberately stays on the
//! libc interface. Spawn is fork + execvp + pipe + dup2; the proxy loop uses
//! poll(2). See irreducibleShims in the task report.
//!
//! Configuration (env vars):
//!   CAVEMAN_SHRINK_FIELDS   comma-separated extra field names to compress
//!                           (default: description)
//!   CAVEMAN_SHRINK_DEBUG=1  log compression deltas to stderr

const std = @import("std");
const c = std.c;
const compress_mod = @import("compress.zig");
const compress = compress_mod.compress;

// ── libc decls not surfaced under these names in std.c for this dev build ────
extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn close(fd: c_int) c_int;

const POLLIN: c_short = 0x0001;

// ── Spawn ────────────────────────────────────────────────────────────────────

const Child = struct {
    pid: c.pid_t,
    /// Write end of the child's stdin (we write here → child reads on fd 0).
    stdin_w: c.fd_t,
    /// Read end of the child's stdout (child writes fd 1 → we read here).
    stdout_r: c.fd_t,
};

const SpawnError = error{
    PipeFailed,
    ForkFailed,
    OutOfMemory,
};

/// Spawn `argv[0]` with `argv[1..]`, wiring child stdin/stdout to pipes and
/// inheriting stderr (matches the JS `stdio: ['pipe','pipe','inherit']`).
///
/// POSIX-only: the JS `spawn-options.js` sets `shell: true` ONLY on win32 (for
/// .cmd / PATHEXT resolution). On POSIX it spawns directly with shell:false, so
/// this fork+execvp path is the faithful POSIX behavior. Windows is out of
/// scope for this binary (the hooks codebase is POSIX-libc throughout).
fn spawn(gpa: std.mem.Allocator, argv: []const [:0]const u8) SpawnError!Child {
    var in_fds: [2]c.fd_t = undefined; // [read, write]
    var out_fds: [2]c.fd_t = undefined; // [read, write]
    if (c.pipe(&in_fds) != 0) return error.PipeFailed;
    if (c.pipe(&out_fds) != 0) {
        _ = close(in_fds[0]);
        _ = close(in_fds[1]);
        return error.PipeFailed;
    }

    // Build a NULL-terminated argv for execvp.
    const cargv = gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch {
        _ = close(in_fds[0]);
        _ = close(in_fds[1]);
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        return error.OutOfMemory;
    };
    defer gpa.free(cargv);
    for (argv, 0..) |a, i| cargv[i] = a.ptr;

    const pid = fork();
    if (pid < 0) {
        _ = close(in_fds[0]);
        _ = close(in_fds[1]);
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child. Wire stdin to in pipe read end, stdout to out pipe write end.
        _ = c.dup2(in_fds[0], 0);
        _ = c.dup2(out_fds[1], 1);
        // Close all pipe fds in the child (the dup2'd copies remain on 0/1).
        _ = close(in_fds[0]);
        _ = close(in_fds[1]);
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        _ = execvp(argv[0].ptr, cargv.ptr);
        // execvp only returns on error.
        c._exit(127);
    }

    // Parent. Close the ends we don't use.
    _ = close(in_fds[0]); // child reads this
    _ = close(out_fds[1]); // child writes this
    return .{ .pid = pid, .stdin_w = in_fds[1], .stdout_r = out_fds[0] };
}

// ── Line buffering ─────────────────────────────────────────────────────────--

/// Accumulates bytes and yields complete `\n`-terminated lines via `onLine`.
/// Mirrors makeLineBuffer in index.js (trimmed-blank lines are skipped).
const LineBuffer = struct {
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *LineBuffer, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// Append a chunk; for each complete line, call `onLine(ctx, line)`.
    fn push(
        self: *LineBuffer,
        gpa: std.mem.Allocator,
        chunk: []const u8,
        comptime Ctx: type,
        ctx: Ctx,
        comptime onLine: fn (Ctx, []const u8) void,
    ) !void {
        try self.buf.appendSlice(gpa, chunk);
        while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
            const line = self.buf.items[0..nl];
            if (std.mem.trim(u8, line, " \t\r\n").len != 0) {
                onLine(ctx, line);
            }
            // Drop the consumed line + newline from the front.
            const remaining = self.buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[nl + 1 ..]);
            self.buf.shrinkRetainingCapacity(remaining);
        }
    }

    fn flush(
        self: *LineBuffer,
        gpa: std.mem.Allocator,
        comptime Ctx: type,
        ctx: Ctx,
        comptime onLine: fn (Ctx, []const u8) void,
    ) void {
        if (std.mem.trim(u8, self.buf.items, " \t\r\n").len != 0) {
            onLine(ctx, self.buf.items);
        }
        self.buf.clearRetainingCapacity();
        _ = gpa;
    }
};

// ── JSON transform ───────────────────────────────────────────────────────────

const LIST_ARRAYS = [_][]const u8{ "tools", "prompts", "resources", "resourceTemplates" };

/// Compress description-style fields on a list response. Returns the
/// re-serialized JSON line, or null if the message isn't a transformable list
/// response (caller passes the original line through unchanged).
///
/// Mirrors transformResponse in index.js: only touches result.{tools,...}[]
/// .<field>; if nothing matched at the top level, walks the whole result tree
/// (compressDescriptionsInPlace) so servers that nest descriptions are covered.
fn transformLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    fields: []const []const u8,
    debug: bool,
) ?[]u8 {
    // A local arena owns: the parsed tree AND every compressed-string we splice
    // into it. Both are freed together when this function returns, after the
    // result has been serialized into a gpa-owned buffer.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch return null;

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const result_val = root.get("result") orelse return null;
    const result = switch (result_val) {
        .object => |o| o,
        else => return null,
    };

    var compressed_something = false;

    for (LIST_ARRAYS) |array_name| {
        const arr_val = result.getPtr(array_name) orelse continue;
        const arr = switch (arr_val.*) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |*item_val| {
            const item_ptr = switch (item_val.*) {
                .object => item_val,
                else => continue,
            };
            const item = item_ptr.object;
            for (fields) |field| {
                const fv_ptr = item.getPtr(field) orelse continue;
                const before = switch (fv_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                const out = compress(arena, before) catch continue;
                if (!std.mem.eql(u8, out, before)) {
                    fv_ptr.* = .{ .string = out };
                    compressed_something = true;
                    if (debug) {
                        const name = nameOf(item);
                        std.debug.print(
                            "[caveman-shrink] {s}.{s}.{s}: {d}→{d} bytes\n",
                            .{ array_name, name, field, before.len, out.len },
                        );
                    }
                }
            }
        }
    }

    if (!compressed_something) {
        // Deep-walk the result subtree, compressing nested `field` strings.
        compressed_something = compressInPlace(arena, result_val, fields);
    }
    if (!compressed_something) return null;

    // Re-serialize the (possibly mutated) root into a gpa-owned buffer.
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{}) catch null;
}

fn nameOf(obj: std.json.ObjectMap) []const u8 {
    const n = obj.get("name") orelse return "?";
    return switch (n) {
        .string => |s| s,
        else => "?",
    };
}

/// Walk a Value tree (by mutable pointer), compressing every `field`-named
/// string in place. Mirrors compressDescriptionsInPlace in compress.js.
/// Compressed strings are allocated from `arena` (caller owns the arena).
fn compressInPlace(arena: std.mem.Allocator, value: std.json.Value, fields: []const []const u8) bool {
    var changed = false;
    switch (value) {
        .array => |a| {
            for (a.items) |*child| {
                if (compressInPlace(arena, child.*, fields)) changed = true;
            }
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const vp = entry.value_ptr;
                var is_field = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f, key)) {
                        is_field = true;
                        break;
                    }
                }
                if (is_field and vp.* == .string) {
                    const out = compress(arena, vp.*.string) catch continue;
                    if (!std.mem.eql(u8, out, vp.*.string)) {
                        vp.* = .{ .string = out };
                        changed = true;
                    }
                } else {
                    if (compressInPlace(arena, vp.*, fields)) changed = true;
                }
            }
        },
        else => {},
    }
    return changed;
}

// ── Proxy loop ───────────────────────────────────────────────────────────────

const ProxyCtx = struct {
    gpa: std.mem.Allocator,
    fields: []const []const u8,
    debug: bool,
    child_stdin: c.fd_t,
};

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

/// Upstream stdout line → transform → our stdout.
fn onUpstreamLine(ctx: *ProxyCtx, line: []const u8) void {
    if (transformLine(ctx.gpa, line, ctx.fields, ctx.debug)) |out| {
        defer ctx.gpa.free(out);
        writeAll(1, out);
        writeAll(1, "\n");
    } else {
        // Unparseable or non-list → pass through unchanged.
        writeAll(1, line);
        writeAll(1, "\n");
    }
}

/// Client stdin → upstream stdin, pass through unchanged (v1).
fn onClientLine(ctx: *ProxyCtx, line: []const u8) void {
    writeAll(ctx.child_stdin, line);
    writeAll(ctx.child_stdin, "\n");
}

/// Run the bidirectional pump until both ends close. Returns nothing; the
/// caller waitpid()s the child for the exit code.
fn pump(ctx: *ProxyCtx, child: Child) void {
    const gpa = ctx.gpa;
    var up_buf: LineBuffer = .{};
    defer up_buf.deinit(gpa);
    var cl_buf: LineBuffer = .{};
    defer cl_buf.deinit(gpa);

    var stdin_open = true;
    var stdout_open = true;
    var read_buf: [4096]u8 = undefined;

    while (stdin_open or stdout_open) {
        var fds: [2]c.pollfd = undefined;
        var n: usize = 0;
        var stdin_slot: ?usize = null;
        var stdout_slot: ?usize = null;
        if (stdin_open) {
            fds[n] = .{ .fd = 0, .events = POLLIN, .revents = 0 };
            stdin_slot = n;
            n += 1;
        }
        if (stdout_open) {
            fds[n] = .{ .fd = child.stdout_r, .events = POLLIN, .revents = 0 };
            stdout_slot = n;
            n += 1;
        }
        if (n == 0) break;

        const rc = c.poll(&fds, @intCast(n), -1);
        if (rc < 0) break;

        // Client stdin → upstream.
        if (stdin_slot) |slot| {
            if (fds[slot].revents & (POLLIN | 0x0010 | 0x0008) != 0) { // POLLIN|POLLHUP|POLLERR
                const r = c.read(0, &read_buf, read_buf.len);
                if (r <= 0) {
                    stdin_open = false;
                    cl_buf.flush(gpa, *ProxyCtx, ctx, onClientLine);
                    // EOF from client → close upstream stdin so it can exit.
                    _ = close(child.stdin_w);
                } else {
                    cl_buf.push(gpa, read_buf[0..@intCast(r)], *ProxyCtx, ctx, onClientLine) catch {};
                }
            }
        }

        // Upstream stdout → client.
        if (stdout_slot) |slot| {
            if (fds[slot].revents & (POLLIN | 0x0010 | 0x0008) != 0) {
                const r = c.read(child.stdout_r, &read_buf, read_buf.len);
                if (r <= 0) {
                    stdout_open = false;
                    up_buf.flush(gpa, *ProxyCtx, ctx, onUpstreamLine);
                    _ = close(child.stdout_r);
                    if (stdin_open) {
                        stdin_open = false;
                        _ = close(child.stdin_w);
                    }
                } else {
                    up_buf.push(gpa, read_buf[0..@intCast(r)], *ProxyCtx, ctx, onUpstreamLine) catch {};
                }
            }
        }
    }
}

// ── main ─────────────────────────────────────────────────────────────────────

fn parseFields(gpa: std.mem.Allocator) ![]const []const u8 {
    const raw = blk: {
        const p = c.getenv("CAVEMAN_SHRINK_FIELDS") orelse break :blk "description";
        const s = std.mem.sliceTo(p, 0);
        break :blk if (s.len == 0) "description" else s;
    };
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, trimmed));
    }
    if (list.items.len == 0) {
        try list.append(gpa, try gpa.dupe(u8, "description"));
    }
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // argv[0] is the proxy binary; argv[1..] is the upstream command. Use the
    // no-alloc POSIX arg iterator (matches stats.zig — keeps us on the libc
    // C-ABI surface). Each arg is already a NUL-terminated [:0]const u8, so we
    // can hand the pointers straight to execvp.
    var arg_it = init.args.iterate();
    defer arg_it.deinit();
    var argv: std.ArrayList([:0]const u8) = .empty;
    _ = arg_it.skip(); // skip our own name
    while (arg_it.next()) |a| {
        try argv.append(arena, a);
    }

    if (argv.items.len == 0) {
        const msg = "caveman-shrink: missing upstream command.\n" ++
            "Usage: caveman-shrink <upstream-command> [...args]\n";
        writeAll(2, msg);
        std.process.exit(2);
    }

    const debug = blk: {
        const p = c.getenv("CAVEMAN_SHRINK_DEBUG") orelse break :blk false;
        break :blk std.mem.eql(u8, std.mem.sliceTo(p, 0), "1");
    };
    const fields = try parseFields(arena);

    const child = spawn(arena, argv.items) catch |err| {
        const m = switch (err) {
            error.PipeFailed => "caveman-shrink: failed to create pipes\n",
            error.ForkFailed => "caveman-shrink: failed to fork\n",
            error.OutOfMemory => "caveman-shrink: out of memory\n",
        };
        writeAll(2, m);
        std.process.exit(1);
    };

    var ctx: ProxyCtx = .{
        .gpa = gpa,
        .fields = fields,
        .debug = debug,
        .child_stdin = child.stdin_w,
    };
    pump(&ctx, child);

    // Reap the child and mirror its exit status.
    var status: c_int = 0;
    _ = c.waitpid(child.pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (c.W.IFEXITED(ustatus)) {
        std.process.exit(c.W.EXITSTATUS(ustatus));
    }
    if (c.W.IFSIGNALED(ustatus)) {
        const sig: u32 = @intFromEnum(c.W.TERMSIG(ustatus));
        std.process.exit(@intCast(128 + (sig & 0xff)));
    }
    std.process.exit(0);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(compress_mod);
}

const testing = std.testing;

test "transformLine compresses tools[].description, preserves structure" {
    const gpa = testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"reader","description":"Please read the file at src/index.js and just return the contents."}]}}
    ;
    const out = transformLine(gpa, line, &.{"description"}, false).?;
    defer gpa.free(out);
    // Compressed text present, code path src/index.js preserved.
    try testing.expect(std.mem.indexOf(u8, out, "src/index.js") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read file at src/index.js") != null);
    // "Please" and "just" dropped.
    try testing.expect(std.mem.indexOf(u8, out, "Please") == null);
    // Structural fields preserved.
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"reader\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
}

test "transformLine passes through non-list result (no tools/prompts array)" {
    const gpa = testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"the result is here"}]}}
    ;
    // result has no tools/prompts/resources; only the deep-walk applies, and it
    // only touches `description` keys — `text` isn't one, so nothing changes.
    try testing.expect(transformLine(gpa, line, &.{"description"}, false) == null);
}

test "transformLine returns null for non-JSON line (passthrough)" {
    const gpa = testing.allocator;
    try testing.expect(transformLine(gpa, "not json at all", &.{"description"}, false) == null);
    // A JSON message with no result is also passed through unchanged.
    try testing.expect(transformLine(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}", &.{"description"}, false) == null);
}

test "transformLine deep-walks nested description when no top-level array matched" {
    const gpa = testing.allocator;
    const line =
        \\{"result":{"meta":{"description":"This is a really simple thing."}}}
    ;
    const out = transformLine(gpa, line, &.{"description"}, false).?;
    defer gpa.free(out);
    // "really" filler dropped by the nested walk.
    try testing.expect(std.mem.indexOf(u8, out, "really") == null);
    try testing.expect(std.mem.indexOf(u8, out, "simple thing") != null);
}

test "transformLine respects extra field names" {
    const gpa = testing.allocator;
    const line =
        \\{"result":{"tools":[{"name":"x","title":"Please run the build."}]}}
    ;
    const out = transformLine(gpa, line, &.{ "description", "title" }, false).?;
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Please") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Run build") != null);
}

test "transformLine returns null when JSON needs no mutation" {
    const gpa = testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"reader","description":"src/index.js"}]}}
    ;
    try testing.expect(transformLine(gpa, line, &.{"description"}, false) == null);
}
