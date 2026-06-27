//! Caveman/Ponytail stats binary — Zig 0.16 PoC.
//!
//! Port of src/hooks/caveman-stats.js (the default `/caveman-stats` path).
//! Reads the active Claude Code session JSONL (passed via --session-file),
//! sums output + cache-read tokens, prices the session by model, derives the
//! estimated savings (mean 65% from benchmarks/), appends a snapshot line to
//! the lifetime history log, and writes the pre-rendered statusline savings
//! suffix through the SYMLINK-SAFE flag write in common.zig. Then prints the
//! human-readable stats block to stdout — byte-identical to the JS formatter
//! so the differential check can pin to it.
//!
//! Scope vs the JS: this binary covers the hot path the hook actually invokes —
//! parse one session, print formatStats, refresh the suffix. The lifetime
//! aggregation flags (--all / --since), the --share one-liner, and the
//! compressed-memory pair scan are intentionally out of scope for the PoC
//! (no fixture exercises them through the hook). The savings math, pricing
//! table, formatUsd / humanizeTokens / thousands grouping, history append, and
//! suffix aggregate are all reproduced exactly.
//!
//! libc C-ABI throughout (std.c) — matches main.zig / activate.zig /
//! statusline.zig / common.zig. std.json handles the JSONL parsing (correct,
//! not hand-rolled). Never blocks: every filesystem error silent-fails.

const std = @import("std");
const common = @import("common.zig");
const c = std.c;

const TOOL = common.TOOL;

// Mean per-task savings from benchmarks/results/*.json. Only 'full' has
// measured data; lite / ultra / wenyan modes show no estimate. Mirrors the JS
// COMPRESSION table.
pub const FULL_COMPRESSION_RATIO: f64 = 0.65;

/// COMPRESSION[mode] equivalent: returns the savings ratio for a mode, or null
/// if no benchmark data exists for it. Only 'full' is measured.
pub fn compressionRatio(mode: ?[]const u8) ?f64 {
    const m = mode orelse return null;
    if (std.mem.eql(u8, m, "full")) return FULL_COMPRESSION_RATIO;
    return null;
}

const PriceEntry = struct { prefix: []const u8, price: f64 };

/// Approximate Anthropic public output-token pricing, USD per million.
/// Matched by model-id prefix, MOST-SPECIFIC FIRST — priceForModel returns the
/// first match. Byte-for-byte port of MODEL_OUTPUT_PRICE_PER_M in the JS.
pub const MODEL_OUTPUT_PRICE_PER_M = [_]PriceEntry{
    .{ .prefix = "claude-opus-4-0", .price = 75.00 },
    .{ .prefix = "claude-opus-4-1", .price = 75.00 },
    .{ .prefix = "claude-opus-4-2025", .price = 75.00 },
    .{ .prefix = "claude-opus-4", .price = 25.00 },
    .{ .prefix = "claude-sonnet-4", .price = 15.00 },
    .{ .prefix = "claude-haiku-4", .price = 5.00 },
    .{ .prefix = "claude-3-5-sonnet", .price = 15.00 },
    .{ .prefix = "claude-3-5-haiku", .price = 4.00 },
    .{ .prefix = "claude-3-opus", .price = 75.00 },
};

/// First-prefix-match price lookup. null when model is null or unmatched.
pub fn priceForModel(model: ?[]const u8) ?f64 {
    const m = model orelse return null;
    for (MODEL_OUTPUT_PRICE_PER_M) |e| {
        if (std.mem.startsWith(u8, m, e.prefix)) return e.price;
    }
    return null;
}

/// JS Number.prototype.toFixed semantics for our use: round-half-away-from-zero
/// to `digits` decimals, returning the string into `buf`. Values here are small
/// and positive (USD savings); the rounding rule matches toFixed for these.
fn fixed(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, amount: f64, digits: u8) !void {
    var scale: f64 = 1;
    var i: u8 = 0;
    while (i < digits) : (i += 1) scale *= 10;
    const scaled = @round(amount * scale);
    const int_part: u64 = @intFromFloat(scaled / scale);
    // Fractional digits as an integer with leading zeros preserved.
    const frac: u64 = @intFromFloat(@round(scaled - @as(f64, @floatFromInt(int_part)) * scale));
    try buf.print(gpa, "{d}", .{int_part});
    if (digits > 0) {
        try buf.append(gpa, '.');
        // zero-pad frac to `digits` width
        var fbuf: [20]u8 = undefined;
        const fs = std.fmt.bufPrint(&fbuf, "{d}", .{frac}) catch return;
        var pad = digits - @as(u8, @intCast(fs.len));
        while (pad > 0) : (pad -= 1) try buf.append(gpa, '0');
        try buf.appendSlice(gpa, fs);
    }
}

/// formatUsd — mirrors the JS tiered precision:
///   >= 1    → "$X.XX"   (2 decimals)
///   >= 0.01 → "$X.XXX"  (3 decimals)
///   else    → "$X.XXXX" (4 decimals)
pub fn formatUsd(gpa: std.mem.Allocator, amount: f64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '$');
    const digits: u8 = if (amount >= 1) 2 else if (amount >= 0.01) 3 else 4;
    try fixed(&buf, gpa, amount, digits);
    return buf.toOwnedSlice(gpa);
}

/// humanizeTokens — mirrors the JS:
///   <= 0 / non-finite → "0"
///   >= 1e6 → "(n/1e6).toFixed(1)M"
///   >= 1e3 → "(n/1e3).toFixed(1)k"
///   else   → String(round(n))
pub fn humanizeTokens(gpa: std.mem.Allocator, n: f64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (!std.math.isFinite(n) or n <= 0) {
        try buf.appendSlice(gpa, "0");
    } else if (n >= 1e6) {
        try fixed(&buf, gpa, n / 1e6, 1);
        try buf.append(gpa, 'M');
    } else if (n >= 1e3) {
        try fixed(&buf, gpa, n / 1e3, 1);
        try buf.append(gpa, 'k');
    } else {
        const r: i64 = @intFromFloat(@round(n));
        try buf.print(gpa, "{d}", .{r});
    }
    return buf.toOwnedSlice(gpa);
}

/// Render an integer with comma thousands separators (en-US toLocaleString for
/// integers). Negative values keep the sign; grouping applies to the magnitude.
pub fn grouped(gpa: std.mem.Allocator, value: i64) ![]u8 {
    var tmp: [24]u8 = undefined;
    const mag: u64 = absMagnitude(value);
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{mag}) catch unreachable;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (value < 0) try out.append(gpa, '-');
    const len = digits.len;
    for (digits, 0..) |ch, idx| {
        if (idx > 0 and (len - idx) % 3 == 0) try out.append(gpa, ',');
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

fn absMagnitude(value: i64) u64 {
    if (value >= 0) return @intCast(value);
    const plus_one = value + 1;
    return @as(u64, @intCast(-plus_one)) + 1;
}

/// One parsed session snapshot — the four fields the JS parseSession returns.
pub const Session = struct {
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    turns: i64 = 0,
    model: ?[]u8 = null, // owned; first model id seen on an assistant turn

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        if (self.model) |m| gpa.free(m);
        self.model = null;
    }
};

fn asInt(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| floatToI64(f),
        else => 0,
    };
}

fn floatToI64(f: f64) i64 {
    if (!std.math.isFinite(f)) return 0;
    const rounded = @round(f);
    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (rounded >= max_f) return std.math.maxInt(i64);
    if (rounded <= min_f) return std.math.minInt(i64);
    return @intFromFloat(rounded);
}

fn addClamped(acc: *i64, delta: i64) void {
    acc.* = std.math.add(i64, acc.*, delta) catch if (delta >= 0) std.math.maxInt(i64) else std.math.minInt(i64);
}

/// Parse the session JSONL line-by-line, tolerating malformed lines (exactly
/// like the JS: blank lines skipped, JSON.parse failures skipped). Only
/// type=="assistant" entries with a message.usage are counted. Captures the
/// FIRST model id encountered.
pub fn parseSession(gpa: std.mem.Allocator, raw: []const u8) Session {
    var s: Session = .{};
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const t = obj.get("type") orelse continue;
        const tstr = switch (t) {
            .string => |str| str,
            else => continue,
        };
        if (!std.mem.eql(u8, tstr, "assistant")) continue;
        const msg = obj.get("message") orelse continue;
        const mobj = switch (msg) {
            .object => |o| o,
            else => continue,
        };
        const usage = mobj.get("usage") orelse continue;
        const uobj = switch (usage) {
            .object => |o| o,
            else => continue,
        };
        if (uobj.get("output_tokens")) |v| addClamped(&s.output_tokens, asInt(v));
        if (uobj.get("cache_read_input_tokens")) |v| addClamped(&s.cache_read_tokens, asInt(v));
        addClamped(&s.turns, 1);
        if (s.model == null) {
            if (mobj.get("model")) |mv| switch (mv) {
                .string => |ms| s.model = gpa.dupe(u8, ms) catch null,
                else => {},
            };
        }
    }
    return s;
}

pub const Savings = struct { est_saved_tokens: i64, est_saved_usd: f64 };

/// deriveSavings — port of the JS. With no ratio (unbenchmarked mode) returns
/// zeros. estNormal = round(output / (1 - ratio)); saved = estNormal - output;
/// usd = price ? (saved/1e6)*price : 0.
pub fn deriveSavings(output_tokens: i64, mode: ?[]const u8, model: ?[]const u8) Savings {
    const ratio = compressionRatio(mode) orelse return .{ .est_saved_tokens = 0, .est_saved_usd = 0 };
    const out_f: f64 = @floatFromInt(output_tokens);
    const est_normal: i64 = @intFromFloat(@round(out_f / (1.0 - ratio)));
    const saved = est_normal - output_tokens;
    const usd = if (priceForModel(model)) |price|
        (@as(f64, @floatFromInt(saved)) / 1_000_000.0) * price
    else
        0;
    return .{ .est_saved_tokens = saved, .est_saved_usd = usd };
}

const SEP = "──────────────────────────────────";

/// Shorten a session path the way the JS does: > 45 chars → "..." + last 45.
fn shortPath(path: []const u8) []const u8 {
    if (path.len > 45) return path[path.len - 45 ..];
    return path;
}

/// formatStats — byte-for-byte port of the JS formatter for the in-scope paths
/// (turns==0; benchmarked 'full' mode with/without a known price; unbenchmarked
/// mode; inactive). The compressed-memory line is omitted (out of scope).
pub fn formatStats(
    gpa: std.mem.Allocator,
    session: Session,
    mode: ?[]const u8,
    session_path: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (session.turns == 0) {
        try out.print(gpa, "\nCaveman Stats\n{s}\nNo conversation yet — stats available after first response.\n{s}\n", .{ SEP, SEP });
        return out.toOwnedSlice(gpa);
    }

    const ratio = compressionRatio(mode);
    const price = priceForModel(session.model);

    // Header.
    try out.print(gpa, "\nCaveman Stats\n{s}\n", .{SEP});
    const sp = shortPath(session_path);
    if (sp.len > 0) {
        if (session_path.len > 45) {
            try out.print(gpa, "Session:  ...{s}\n", .{sp});
        } else {
            try out.print(gpa, "Session:  {s}\n", .{sp});
        }
    }
    {
        const turns_s = try grouped(gpa, session.turns);
        defer gpa.free(turns_s);
        try out.print(gpa, "Turns:    {s}\n{s}\n", .{ turns_s, SEP });
    }
    {
        const ot = try grouped(gpa, session.output_tokens);
        defer gpa.free(ot);
        const cr = try grouped(gpa, session.cache_read_tokens);
        defer gpa.free(cr);
        try out.print(gpa, "Output tokens:         {s}\nCache-read tokens:     {s}\n{s}\n", .{ ot, cr, SEP });
    }

    // Savings block + footer.
    if (ratio) |r| {
        const out_f: f64 = @floatFromInt(session.output_tokens);
        const est_normal: i64 = @intFromFloat(@round(out_f / (1.0 - r)));
        const est_saved = est_normal - session.output_tokens;
        const en = try grouped(gpa, est_normal);
        defer gpa.free(en);
        const es = try grouped(gpa, est_saved);
        defer gpa.free(es);
        const pct: i64 = @intFromFloat(@round(r * 100.0));
        try out.print(gpa, "Est. without caveman:  {s}\nEst. tokens saved:     {s} (~{d}%)\n", .{ en, es, pct });
        if (price) |p| {
            const usd = (@as(f64, @floatFromInt(est_saved)) / 1_000_000.0) * p;
            const usd_s = try formatUsd(gpa, usd);
            defer gpa.free(usd_s);
            try out.print(gpa, "Est. saved (USD):      ~{s}\n", .{usd_s});
            try out.print(gpa, "Savings est. from benchmarks/ (mean per-task). Pricing for {s}. Actual varies by task.\n", .{session.model.?});
        } else {
            try out.appendSlice(gpa, "Savings est. from benchmarks/ (mean per-task). Actual varies by task.\n");
        }
    } else if (mode != null and !std.mem.eql(u8, mode.?, "off")) {
        try out.print(gpa, "No savings estimate for '{s}' mode — only 'full' has benchmark data.\n", .{mode.?});
    } else {
        try out.appendSlice(gpa, "Caveman not active this session.\n");
    }

    return out.toOwnedSlice(gpa);
}

// ── History aggregation (for the statusline suffix) ──────────────────────────

/// Sum est_saved_tokens across the LATEST snapshot per session_id in the
/// history JSONL — mirrors aggregateHistory with no --since filter, restricted
/// to the one field the suffix needs. Tolerates malformed lines.
pub fn aggregateSavedTokens(gpa: std.mem.Allocator, history_raw: []const u8) i64 {
    // session_id -> {ts, est_saved_tokens}; keep the entry with the largest ts.
    var latest = std.StringHashMap(struct { ts: i64, saved: i64 }).init(gpa);
    defer {
        var kit = latest.keyIterator();
        while (kit.next()) |k| gpa.free(k.*);
        latest.deinit();
    }

    var it = std.mem.splitScalar(u8, history_raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const ts: i64 = if (obj.get("ts")) |v| asInt(v) else 0;
        const saved: i64 = if (obj.get("est_saved_tokens")) |v| asInt(v) else 0;
        const id: []const u8 = if (obj.get("session_id")) |v| switch (v) {
            .string => |s| s,
            else => "_",
        } else "_";

        if (latest.getEntry(id)) |entry| {
            if (ts >= entry.value_ptr.ts) entry.value_ptr.* = .{ .ts = ts, .saved = saved };
        } else {
            const owned = gpa.dupe(u8, id) catch continue;
            latest.put(owned, .{ .ts = ts, .saved = saved }) catch {
                gpa.free(owned);
                continue;
            };
        }
    }

    var total: i64 = 0;
    var vit = latest.valueIterator();
    while (vit.next()) |v| addClamped(&total, v.saved);
    return total;
}

/// Append a JSON-escaped string literal (including the surrounding quotes) the
/// way JSON.stringify does for the characters that appear in model ids /
/// session ids: ", \, and control bytes < 0x20. Mirrors the JS output so a
/// textual diff of the history file lines up.
fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print(gpa, "\\u{x:0>4}", .{ch});
                } else {
                    try out.append(gpa, ch);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

/// Build the JSON snapshot line the JS appends to history. Field order matches
/// the JS object literal so a textual diff of history files lines up.
fn snapshotLine(
    gpa: std.mem.Allocator,
    session_id: []const u8,
    mode: ?[]const u8,
    model: ?[]const u8,
    output_tokens: i64,
    sav: Savings,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{{\"ts\":{d},\"session_id\":", .{common.nowMillis()});
    try appendJsonString(&out, gpa, session_id);
    try out.appendSlice(gpa, ",\"mode\":");
    if (mode) |m| try appendJsonString(&out, gpa, m) else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, ",\"model\":");
    if (model) |m| try appendJsonString(&out, gpa, m) else try out.appendSlice(gpa, "null");
    try out.print(gpa, ",\"output_tokens\":{d},\"est_saved_tokens\":{d},\"est_saved_usd\":", .{ output_tokens, sav.est_saved_tokens });
    // est_saved_usd: JSON number. JS serializes a JS float; for zero it's 0.
    if (sav.est_saved_usd == 0) {
        try out.appendSlice(gpa, "0");
    } else {
        try out.print(gpa, "{d}", .{sav.est_saved_usd});
    }
    try out.appendSlice(gpa, "}");
    return out.toOwnedSlice(gpa);
}

/// Refresh the statusline suffix: append this session's snapshot to history,
/// re-aggregate latest-per-session saved tokens, and write the pre-rendered
/// suffix string ("⛏  <humanized>" or empty) through safeWriteFlag. Best-effort.
pub fn refreshSuffix(
    io: std.Io,
    gpa: std.mem.Allocator,
    session_id: []const u8,
    mode: ?[]const u8,
    session: Session,
    sav: Savings,
) void {
    const hpath = common.historyPath(gpa) catch return;
    defer gpa.free(hpath);

    const line = snapshotLine(gpa, session_id, mode, session.model, session.output_tokens, sav) catch return;
    defer gpa.free(line);
    common.appendHistory(io, hpath, line);

    const raw = common.readHistoryFile(io, gpa, hpath) orelse "";
    const owned = raw.len > 0;
    defer if (owned) gpa.free(raw);
    const total = aggregateSavedTokens(gpa, raw);

    const spath = common.statuslineSuffixPath(gpa) catch return;
    defer gpa.free(spath);

    if (total > 0) {
        const human = humanizeTokens(gpa, @floatFromInt(total)) catch return;
        defer gpa.free(human);
        // JS: `⛏  ${human}` — pickaxe + TWO spaces + humanized value.
        const suffix = std.fmt.allocPrint(gpa, "⛏  {s}", .{human}) catch return;
        defer gpa.free(suffix);
        common.safeWriteFlag(io, gpa, spath, suffix) catch return;
    } else {
        common.safeWriteFlag(io, gpa, spath, "") catch return;
    }
}

// ── main ─────────────────────────────────────────────────────────────────────

/// Scan argv for `--session-file <value>` and return the value. Uses the
/// no-alloc POSIX arg iterator (init, not initAllocator) — keeps us on the
/// libc C-ABI surface, no std.Io. argv0 is consumed via the leading skip.
fn sessionFileArg(args: std.process.Args) ?[:0]const u8 {
    var it = args.iterate();
    defer it.deinit();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--session-file")) return it.next();
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Construct the std.Io backend once; thread it down to every FS fn.
    var threaded = common.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    const session_file = sessionFileArg(init.args) orelse {
        common.writeStderr(TOOL ++ "-stats: no Claude Code session found.\n");
        std.process.exit(1);
    };

    // Read the session JSONL (best-effort; missing file → empty session block).
    const raw = common.readHistoryFile(io, gpa, session_file) orelse "";
    const raw_owned = raw.len > 0;
    defer if (raw_owned) gpa.free(raw);

    var session = parseSession(gpa, raw);
    defer session.deinit(gpa);

    const flagp = common.flagPath(gpa) catch null;
    defer if (flagp) |p| gpa.free(p);
    const mode: ?[]const u8 = if (flagp) |p| common.readFlagMode(io, gpa, p) else null;

    if (session.turns > 0) {
        const sav = deriveSavings(session.output_tokens, mode, session.model);
        const session_id = sessionIdFromPath(session_file);
        refreshSuffix(io, gpa, session_id, mode, session, sav);
    }

    const block = try formatStats(gpa, session, mode, session_file);
    defer gpa.free(block);
    common.writeStdout(block);
}

/// basename of the session file without its ".jsonl" extension — matches the JS
/// path.basename(sessionFile, '.jsonl').
fn sessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) return base[0 .. base.len - ".jsonl".len];
    return base;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(common);
}

test "priceForModel prefix matching, most-specific first" {
    // Dated Opus 4.0 → legacy $75 tier (claude-opus-4-2025 matches before
    // claude-opus-4).
    try std.testing.expectEqual(@as(f64, 75.0), priceForModel("claude-opus-4-20250514").?);
    try std.testing.expectEqual(@as(f64, 75.0), priceForModel("claude-opus-4-0").?);
    try std.testing.expectEqual(@as(f64, 75.0), priceForModel("claude-opus-4-1-20250805").?);
    // Opus 4.5+ → $25.
    try std.testing.expectEqual(@as(f64, 25.0), priceForModel("claude-opus-4-5-20251101").?);
    try std.testing.expectEqual(@as(f64, 15.0), priceForModel("claude-sonnet-4-20250514").?);
    try std.testing.expectEqual(@as(f64, 5.0), priceForModel("claude-haiku-4-5").?);
    try std.testing.expectEqual(@as(f64, 15.0), priceForModel("claude-3-5-sonnet-20241022").?);
    try std.testing.expectEqual(@as(f64, 4.0), priceForModel("claude-3-5-haiku-20241022").?);
    try std.testing.expectEqual(@as(f64, 75.0), priceForModel("claude-3-opus-20240229").?);
    try std.testing.expect(priceForModel("gpt-4o") == null);
    try std.testing.expect(priceForModel(null) == null);
}

test "formatUsd tiered precision" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: f64, want: []const u8 }{
        .{ .in = 0.076575, .want = "$0.077" }, // >=0.01 → 3 decimals
        .{ .in = 0.005, .want = "$0.0050" }, // <0.01 → 4 decimals
        .{ .in = 1.5, .want = "$1.50" }, // >=1 → 2 decimals
        .{ .in = 0.0004, .want = "$0.0004" },
        .{ .in = 12.345, .want = "$12.35" }, // rounds to 2
    };
    for (cases) |ca| {
        const got = try formatUsd(gpa, ca.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(ca.want, got);
    }
}

test "humanizeTokens thresholds" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: f64, want: []const u8 }{
        .{ .in = 0, .want = "0" },
        .{ .in = -5, .want = "0" },
        .{ .in = 550, .want = "550" },
        .{ .in = 1021, .want = "1.0k" },
        .{ .in = 1500, .want = "1.5k" },
        .{ .in = 1_500_000, .want = "1.5M" },
    };
    for (cases) |ca| {
        const got = try humanizeTokens(gpa, ca.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(ca.want, got);
    }
}

test "grouped thousands separators" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: i64, want: []const u8 }{
        .{ .in = 0, .want = "0" },
        .{ .in = 550, .want = "550" },
        .{ .in = 4000, .want = "4,000" },
        .{ .in = 1021, .want = "1,021" },
        .{ .in = 1234567, .want = "1,234,567" },
        .{ .in = -4000, .want = "-4,000" },
        .{ .in = std.math.minInt(i64), .want = "-9,223,372,036,854,775,808" },
    };
    for (cases) |ca| {
        const got = try grouped(gpa, ca.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(ca.want, got);
    }
}

test "parseSession sums tokens over fixture JSONL, captures first model" {
    const gpa = std.testing.allocator;
    const fixture =
        \\{"type":"summary","summary":"x"}
        \\{"type":"assistant","message":{"model":"claude-opus-4-20250514","usage":{"output_tokens":120,"cache_read_input_tokens":2000}}}
        \\not valid json line
        \\{"type":"user","message":{"content":"hi"}}
        \\{"type":"assistant","message":{"model":"claude-opus-4-20250514","usage":{"output_tokens":80,"cache_read_input_tokens":1500}}}
        \\{"type":"assistant","message":{"usage":{"output_tokens":50}}}
        \\
        \\{"type":"assistant","message":{"model":"claude-sonnet-4-20250514","usage":{"output_tokens":300,"cache_read_input_tokens":500}}}
    ;
    var s = parseSession(gpa, fixture);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 550), s.output_tokens); // 120+80+50+300
    try std.testing.expectEqual(@as(i64, 4000), s.cache_read_tokens); // 2000+1500+0+500
    try std.testing.expectEqual(@as(i64, 4), s.turns);
    try std.testing.expectEqualStrings("claude-opus-4-20250514", s.model.?); // first wins
}

test "parseSession clamps overflowing token counters" {
    const gpa = std.testing.allocator;
    const max = "9223372036854775807";
    const fixture =
        "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":" ++ max ++ ",\"cache_read_input_tokens\":" ++ max ++ "}}}\n" ++
        "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":1,\"cache_read_input_tokens\":1}}}\n";
    var s = parseSession(gpa, fixture);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), s.output_tokens);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), s.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 2), s.turns);
}

test "deriveSavings math (full mode, opus legacy price)" {
    const sav = deriveSavings(550, "full", "claude-opus-4-20250514");
    // estNormal = round(550 / 0.35) = round(1571.4) = 1571; saved = 1021.
    try std.testing.expectEqual(@as(i64, 1021), sav.est_saved_tokens);
    // usd = 1021/1e6 * 75 = 0.076575
    try std.testing.expectApproxEqAbs(@as(f64, 0.076575), sav.est_saved_usd, 1e-9);

    // Unbenchmarked mode → zero savings.
    const none = deriveSavings(550, "lite", "claude-opus-4-20250514");
    try std.testing.expectEqual(@as(i64, 0), none.est_saved_tokens);
    try std.testing.expectEqual(@as(f64, 0), none.est_saved_usd);

    // Benchmarked mode but unknown price → tokens saved, usd 0.
    const noprice = deriveSavings(550, "full", "gpt-4o");
    try std.testing.expectEqual(@as(i64, 1021), noprice.est_saved_tokens);
    try std.testing.expectEqual(@as(f64, 0), noprice.est_saved_usd);
}

test "formatStats matches JS layout (full mode, opus)" {
    const gpa = std.testing.allocator;
    var s: Session = .{ .output_tokens = 550, .cache_read_tokens = 4000, .turns = 4 };
    s.model = try gpa.dupe(u8, "claude-opus-4-20250514");
    defer s.deinit(gpa);

    const got = try formatStats(gpa, s, "full", "/tmp/cavestats/session.jsonl");
    defer gpa.free(got);
    const want =
        "\nCaveman Stats\n" ++ SEP ++ "\n" ++
        "Session:  /tmp/cavestats/session.jsonl\n" ++
        "Turns:    4\n" ++ SEP ++ "\n" ++
        "Output tokens:         550\n" ++
        "Cache-read tokens:     4,000\n" ++ SEP ++ "\n" ++
        "Est. without caveman:  1,571\n" ++
        "Est. tokens saved:     1,021 (~65%)\n" ++
        "Est. saved (USD):      ~$0.077\n" ++
        "Savings est. from benchmarks/ (mean per-task). Pricing for claude-opus-4-20250514. Actual varies by task.\n";
    try std.testing.expectEqualStrings(want, got);
}

test "formatStats turns==0 and unbenchmarked mode" {
    const gpa = std.testing.allocator;
    {
        const s: Session = .{};
        const got = try formatStats(gpa, s, "full", "/x.jsonl");
        defer gpa.free(got);
        try std.testing.expectEqualStrings(
            "\nCaveman Stats\n" ++ SEP ++ "\nNo conversation yet — stats available after first response.\n" ++ SEP ++ "\n",
            got,
        );
    }
    {
        var s: Session = .{ .output_tokens = 1234, .cache_read_tokens = 99, .turns = 1 };
        s.model = try gpa.dupe(u8, "claude-sonnet-4-5-20250929");
        defer s.deinit(gpa);
        const got = try formatStats(gpa, s, "lite", "/tmp/cavestats/sonnet.jsonl");
        defer gpa.free(got);
        const want =
            "\nCaveman Stats\n" ++ SEP ++ "\n" ++
            "Session:  /tmp/cavestats/sonnet.jsonl\n" ++
            "Turns:    1\n" ++ SEP ++ "\n" ++
            "Output tokens:         1,234\n" ++
            "Cache-read tokens:     99\n" ++ SEP ++ "\n" ++
            "No savings estimate for 'lite' mode — only 'full' has benchmark data.\n";
        try std.testing.expectEqualStrings(want, got);
    }
}

test "formatStats long path shortening (>45 chars)" {
    const gpa = std.testing.allocator;
    var s: Session = .{ .output_tokens = 550, .cache_read_tokens = 4000, .turns = 4 };
    s.model = try gpa.dupe(u8, "claude-opus-4-20250514");
    defer s.deinit(gpa);
    const p = "/very/long/path/to/some/deeply/nested/projects/dir/abcdef-1234-5678.jsonl";
    const got = try formatStats(gpa, s, "full", p);
    defer gpa.free(got);
    // The JS keeps the last 45 chars prefixed with "...".
    try std.testing.expect(std.mem.indexOf(u8, got, "Session:  ...ly/nested/projects/dir/abcdef-1234-5678.jsonl\n") != null);
}

test "aggregateSavedTokens keeps latest per session_id" {
    const gpa = std.testing.allocator;
    const hist =
        \\{"ts":100,"session_id":"a","est_saved_tokens":10}
        \\{"ts":200,"session_id":"a","est_saved_tokens":50}
        \\{"ts":150,"session_id":"b","est_saved_tokens":7}
        \\garbage
        \\{"ts":50,"session_id":"a","est_saved_tokens":999}
    ;
    // a → latest is ts=200 (50); b → 7. Total 57.
    try std.testing.expectEqual(@as(i64, 57), aggregateSavedTokens(gpa, hist));
    try std.testing.expectEqual(@as(i64, 0), aggregateSavedTokens(gpa, ""));
}

test "aggregateSavedTokens clamps overflowing totals" {
    const gpa = std.testing.allocator;
    const hist =
        "{\"ts\":1,\"session_id\":\"a\",\"est_saved_tokens\":9223372036854775807}\n" ++
        "{\"ts\":1,\"session_id\":\"b\",\"est_saved_tokens\":1}\n";
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), aggregateSavedTokens(gpa, hist));
}

test "refreshSuffix writes ⛏ + humanized lifetime savings" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);

    // Point CLAUDE_CONFIG_DIR at a fresh temp dir so history/suffix land there.
    const old = try common.saveEnv(gpa, "CLAUDE_CONFIG_DIR");
    defer if (old) |v| gpa.free(v);
    defer common.restoreEnv("CLAUDE_CONFIG_DIR", old);
    const cfg = try std.fs.path.join(gpa, &.{ dir, "cfg" });
    defer gpa.free(cfg);
    try common.mkdirPath(io, cfg);
    const cfg_z = try gpa.dupeZ(u8, cfg);
    defer gpa.free(cfg_z);
    _ = common.setenv("CLAUDE_CONFIG_DIR", cfg_z.ptr, 1);

    var s: Session = .{ .output_tokens = 550, .cache_read_tokens = 4000, .turns = 4 };
    s.model = try gpa.dupe(u8, "claude-opus-4-20250514");
    defer s.deinit(gpa);
    const sav = deriveSavings(s.output_tokens, "full", s.model);

    refreshSuffix(io, gpa, "session", "full", s, sav);

    const spath = try common.statuslineSuffixPath(gpa);
    defer gpa.free(spath);
    const got = try common.readSmall(io, gpa, spath);
    defer gpa.free(got);
    // est_saved 1021 → humanize "1.0k" → "⛏  1.0k".
    try std.testing.expectEqualStrings("⛏  1.0k", got);

    // History file got exactly one snapshot line for this session.
    const hpath = try common.historyPath(gpa);
    defer gpa.free(hpath);
    const hist = common.readHistoryFile(io, gpa, hpath).?;
    defer gpa.free(hist);
    try std.testing.expect(std.mem.indexOf(u8, hist, "\"session_id\":\"session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hist, "\"est_saved_tokens\":1021") != null);

    // Cleanup.
    common.unlinkFlag(io, spath);
    common.unlinkFlag(io, hpath);
}

test "refreshSuffix empty suffix when no savings (unbenchmarked mode)" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = std.testing.allocator;
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);

    const old = try common.saveEnv(gpa, "CLAUDE_CONFIG_DIR");
    defer if (old) |v| gpa.free(v);
    defer common.restoreEnv("CLAUDE_CONFIG_DIR", old);
    const cfg = try std.fs.path.join(gpa, &.{ dir, "cfg2" });
    defer gpa.free(cfg);
    try common.mkdirPath(io, cfg);
    const cfg_z = try gpa.dupeZ(u8, cfg);
    defer gpa.free(cfg_z);
    _ = common.setenv("CLAUDE_CONFIG_DIR", cfg_z.ptr, 1);

    var s: Session = .{ .output_tokens = 1234, .cache_read_tokens = 99, .turns = 1 };
    s.model = try gpa.dupe(u8, "claude-sonnet-4-5-20250929");
    defer s.deinit(gpa);
    const sav = deriveSavings(s.output_tokens, "lite", s.model); // no ratio → 0 saved

    refreshSuffix(io, gpa, "session2", "lite", s, sav);

    const spath = try common.statuslineSuffixPath(gpa);
    defer gpa.free(spath);
    const got = try common.readSmall(io, gpa, spath);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("", got);

    common.unlinkFlag(io, spath);
    const hpath = try common.historyPath(gpa);
    defer gpa.free(hpath);
    common.unlinkFlag(io, hpath);
}
