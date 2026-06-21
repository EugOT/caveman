//! Differential driver for compress_protect.zig. Speaks the same length-framed
//! stdin/stdout protocol as zig/scripts/cm_protect_ref.py (the Python reference)
//! so a harness can feed identical fixtures to both and byte-compare:
//!
//!   per request:  read line "<FN> <N>\n" (FN ∈ {fm, sens, strip}), then N bytes.
//!   per reply:
//!     fm    → "<len_fm> <len_body>\n" then fm bytes then body bytes
//!     sens  → "1\n" then "1" | "0\n" then "0"
//!     strip → "<len>\n" then len bytes
//!
//! Pure I/O glue around the module — no logic lives here. I/O goes through the
//! raw libc fds (std.c read(2)/write(2)) to match the established hook pattern
//! (common.zig readStdin/writeStdout) and stay off the in-flight std.Io surface.
//! Allocator: a single DebugAllocator (leak-checked at exit).

const std = @import("std");
const protect = @import("compress_protect.zig");
const c = std.c;

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

fn writeAllStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    const data = try readAllStdin(gpa);
    defer gpa.free(data);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var pos: usize = 0;
    while (pos < data.len) {
        // Parse header line "<FN> <N>\n".
        const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const header = data[pos..nl];
        pos = nl + 1;
        const sp = std.mem.indexOfScalar(u8, header, ' ') orelse return error.BadHeader;
        const fn_name = header[0..sp];
        const count = try std.fmt.parseInt(usize, header[sp + 1 ..], 10);
        if (pos + count > data.len) return error.ShortPayload;
        const payload = data[pos .. pos + count];
        pos += count;

        if (std.mem.eql(u8, fn_name, "fm")) {
            const r = protect.splitFrontmatter(payload);
            try out.print(gpa, "{d} {d}\n", .{ r.frontmatter.len, r.body.len });
            try out.appendSlice(gpa, r.frontmatter);
            try out.appendSlice(gpa, r.body);
        } else if (std.mem.eql(u8, fn_name, "sens")) {
            const res: []const u8 = if (protect.isSensitivePath(payload)) "1" else "0";
            try out.print(gpa, "{d}\n", .{res.len});
            try out.appendSlice(gpa, res);
        } else if (std.mem.eql(u8, fn_name, "strip")) {
            const res = protect.stripLlmWrapper(payload);
            try out.print(gpa, "{d}\n", .{res.len});
            try out.appendSlice(gpa, res);
        } else {
            return error.UnknownFn;
        }
    }

    writeAllStdout(out.items);
}
