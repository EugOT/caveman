//! caveman-compress post-compression integrity validator — Zig 0.16 port of
//! skills/caveman-compress/scripts/validate.py.
//!
//! Pure logic. NO LLM, NO subprocess, allocator-only. Given the ORIGINAL and the
//! COMPRESSED markdown, it re-derives six structural fingerprints and flags any
//! drift the compressor must never introduce:
//!
//!   headings      (error if count differs, warning if text/order differs)
//!   code blocks   (error if the fenced blocks are not byte-identical)
//!   URLs          (error if the https?:// set differs)
//!   paths         (warning if the path set differs)
//!   bullets       (warning if the count moves > 15%)
//!   inline code   (error if any backtick token is lost / count drops;
//!                  warning if a token is added)
//!
//! The Python original leans on `re` (PCRE-ish) and Python `set`/`Counter`.
//! Zig std ships no regex engine, so each pattern is reproduced as a targeted
//! byte-scanner with the same semantics, and the set/multiset comparisons run on
//! `std.StringHashMap`. The line-based fenced-code extractor is a direct
//! translation of the Python state machine (same nested-fence / variable-length
//! rules), not a regex.
//!
//! Determinism note: the Python error strings embed `set` / `Counter` contents
//! whose iteration order is not stable run-to-run. To make the report
//! byte-comparable, this module SORTS every lost/added collection before
//! formatting. The differential harness (validate_diff.py) normalizes the Python
//! side the same way, so the comparison is on a canonical form. The *decisions*
//! (is_valid, which checks fire, counts) are identical to validate.py.
//!
//! API:
//!   validate(gpa, original, compressed) → Result   (caller calls result.deinit)
//!   Result.render(gpa) → owned []u8                (the CLI report block)
//!
//! libc-free: this module is pure std (allocator + slices + std.fmt). Unlike the
//! hook modules it touches no filesystem and no C ABI — the CLI wrapper in main()
//! reads the two files through std.fs.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Result ──────────────────────────────────────────────────────────────────

/// Mirror of validate.py's ValidationResult: a validity flag plus owned error /
/// warning message lists. Messages are heap-allocated; deinit frees them.
pub const Result = struct {
    is_valid: bool = true,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    /// Take ownership of `msg` (already allocated by the caller) as an error.
    /// Sets is_valid = false, matching ValidationResult.add_error.
    fn addError(self: *Result, gpa: Allocator, msg: []const u8) Allocator.Error!void {
        self.is_valid = false;
        try self.errors.append(gpa, msg);
    }

    /// Take ownership of `msg` as a warning (does not touch is_valid).
    fn addWarning(self: *Result, gpa: Allocator, msg: []const u8) Allocator.Error!void {
        try self.warnings.append(gpa, msg);
    }

    pub fn deinit(self: *Result, gpa: Allocator) void {
        for (self.errors.items) |m| gpa.free(m);
        for (self.warnings.items) |m| gpa.free(m);
        self.errors.deinit(gpa);
        self.warnings.deinit(gpa);
    }

    /// Render the human-readable report — byte-identical layout to validate.py's
    /// __main__ block:
    ///
    ///     \nValid: {True|False}\n
    ///     [\nErrors:\n  - <e>\n ...]
    ///     [\nWarnings:\n  - <w>\n ...]
    pub fn render(self: *const Result, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "\nValid: ");
        try out.appendSlice(gpa, if (self.is_valid) "True" else "False");
        try out.append(gpa, '\n');
        if (self.errors.items.len > 0) {
            try out.appendSlice(gpa, "\nErrors:\n");
            for (self.errors.items) |e| {
                try out.appendSlice(gpa, "  - ");
                try out.appendSlice(gpa, e);
                try out.append(gpa, '\n');
            }
        }
        if (self.warnings.items.len > 0) {
            try out.appendSlice(gpa, "\nWarnings:\n");
            for (self.warnings.items) |w| {
                try out.appendSlice(gpa, "  - ");
                try out.appendSlice(gpa, w);
                try out.append(gpa, '\n');
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

// ── Character classes mirroring the Python regex escapes ────────────────────--

/// Python `\s` for ASCII markdown: space, tab, CR, LF, form feed, vertical tab.
fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == 0x0c or ch == 0x0b;
}

/// Python `\w` == [A-Za-z0-9_].
fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

// ── Headings ────────────────────────────────────────────────────────────────
// HEADING_REGEX = ^(#{1,6})\s+(.*)  (re.MULTILINE)
// extract_headings → [(level, title.strip())]. We compare the full ordered list.

const Heading = struct {
    level: []const u8, // the run of '#'
    title: []const u8, // .strip()'d, borrowed from the source text
};

/// Strip leading/trailing whitespace exactly like Python str.strip() over the
/// markdown whitespace set. Returns a borrowed sub-slice.
fn strip(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

/// Iterate `text` line by line (split on '\n'), matching `^(#{1,6})\s+(.*)`
/// against each line. The `.*` in Python (no DOTALL) stops at the newline, which
/// our per-line split already enforces. Trailing '\r' is part of `.*` in Python
/// — so it lands inside the title and is then removed by .strip(); we strip the
/// whole line slice before matching so '\r' never reaches title.
fn extractHeadings(gpa: Allocator, text: []const u8) Allocator.Error!std.ArrayList(Heading) {
    var list: std.ArrayList(Heading) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        // Python's `$`/MULTILINE matches before a trailing '\n'; a trailing '\r'
        // (CRLF) would be consumed by `.*`. We drop a single trailing '\r' so the
        // captured `.*` matches Python on CRLF files, then .strip() runs anyway.
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        // Match ^#{1,6}
        var h: usize = 0;
        while (h < line.len and h < 6 and line[h] == '#') h += 1;
        if (h == 0) continue;
        if (h < line.len and line[h] == '#') continue; // 7+ '#' → not a heading per {1,6} then \s
        // Require at least one \s after the hashes (\s+).
        if (h >= line.len or !isSpace(line[h])) continue;
        var rest = h;
        while (rest < line.len and isSpace(line[rest])) rest += 1;
        try list.append(gpa, .{ .level = line[0..h], .title = strip(line[rest..]) });
    }
    return list;
}

fn headingsEqual(a: []const Heading, b: []const Heading) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.level, y.level)) return false;
        if (!std.mem.eql(u8, x.title, y.title)) return false;
    }
    return true;
}

// ── Fenced code blocks ──────────────────────────────────────────────────────
// Line-based extractor — direct port of extract_code_blocks(). A fence opens on
// a line matching ^(\s{0,3})(`{3,}|~{3,})(.*)$. It closes on a later line whose
// fence char matches, whose fence length >= the opening length, and whose
// trailing text (.strip()) is empty. Unclosed fences are silently skipped.
// Each block is the '\n'-joined run of lines from open through close inclusive.

const Fence = struct { char: u8, len: usize, rest: []const u8 };

/// Match ^(\s{0,3})(`{3,}|~{3,})(.*)$ on a single line (no trailing newline).
fn matchFenceOpen(line: []const u8) ?Fence {
    var i: usize = 0;
    // \s{0,3} — but the Python class \s here is broad; in practice fences use up
    // to 3 leading spaces/tabs. Match up to 3 leading whitespace chars.
    var lead: usize = 0;
    while (i < line.len and lead < 3 and isSpace(line[i])) : (i += 1) lead += 1;
    if (i >= line.len) return null;
    const ch = line[i];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == ch) n += 1;
    if (n < 3) return null;
    return .{ .char = ch, .len = n, .rest = line[i + n ..] };
}

/// Extract the joined fenced-code blocks. Returns an owned list of owned slices.
fn extractCodeBlocks(gpa: Allocator, text: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var blocks: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (blocks.items) |b| gpa.free(b);
        blocks.deinit(gpa);
    }

    // Materialize lines (sans trailing '\r'? — no: Python split('\n') keeps '\r',
    // and the closing test does close_m.group(3).strip()=="" which would strip a
    // lone '\r'. We keep '\r' in the line content but match fence rest with strip
    // semantics, matching Python exactly).
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| try lines.append(gpa, ln);
    }

    var i: usize = 0;
    const nlines = lines.items.len;
    while (i < nlines) {
        const open = matchFenceOpen(lines.items[i]) orelse {
            i += 1;
            continue;
        };
        const fence_char = open.char;
        const fence_len = open.len;

        // Accumulate block lines [open .. close]. Track [start_line, end_line]
        // index range so we can re-slice the original text for an exact join.
        const start_idx = i;
        var end_idx = i; // inclusive; updated when closed
        i += 1;
        var closed = false;
        while (i < nlines) : (i += 1) {
            const cm = matchFenceOpen(lines.items[i]);
            if (cm) |close_fence| {
                if (close_fence.char == fence_char and
                    close_fence.len >= fence_len and
                    strip(close_fence.rest).len == 0)
                {
                    end_idx = i;
                    closed = true;
                    i += 1;
                    break;
                }
            }
        }
        if (closed) {
            // Join lines[start_idx..=end_idx] with '\n' — equals the original
            // substring spanning those lines (each line is a borrowed slice of
            // `text`, split on '\n', so the span between them is exactly the
            // original bytes including any '\r').
            var joined: std.ArrayList(u8) = .empty;
            errdefer joined.deinit(gpa);
            var k = start_idx;
            while (k <= end_idx) : (k += 1) {
                if (k > start_idx) try joined.append(gpa, '\n');
                try joined.appendSlice(gpa, lines.items[k]);
            }
            try blocks.append(gpa, try joined.toOwnedSlice(gpa));
        }
        // Unclosed: i has already advanced to nlines; loop exits.
    }
    return blocks;
}

fn codeBlocksEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ── URLs ────────────────────────────────────────────────────────────────────
// URL_REGEX = https?://[^\s)]+   → set. We collect the unique matches.
// (No \b anchor in Python — match can start mid-word. We scan for "http".)

fn matchUrlEnd(s: []const u8, i: usize) ?usize {
    var j = i;
    if (!std.mem.startsWith(u8, s[j..], "http")) return null;
    j += 4;
    if (j < s.len and s[j] == 's') j += 1;
    if (!std.mem.startsWith(u8, s[j..], "://")) return null;
    j += 3;
    const body_start = j;
    while (j < s.len and !isSpace(s[j]) and s[j] != ')') j += 1;
    if (j == body_start) return null; // `+` requires >=1 char after ://
    return j;
}

/// Collect the set of distinct URL matches. Owned keys live in `set`.
fn collectUrls(gpa: Allocator, text: []const u8, set: *std.StringHashMap(void)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (matchUrlEnd(text, i)) |end| {
            const tok = text[i..end];
            if (!set.contains(tok)) {
                const owned = try gpa.dupe(u8, tok);
                errdefer gpa.free(owned);
                try set.put(owned, {});
            }
            i = end;
            continue;
        }
        i += 1;
    }
}

// ── Paths ───────────────────────────────────────────────────────────────────
// PATH_REGEX (Python):
//   (?:\./|\.\./|/|[A-Za-z]:\\)[\w\-/\\\.]+
//   | [\w\-\.]+[/\\][\w\-/\\\.]+
// → set. Python scans left-to-right, longest the alternation can give at each
// position via the regex engine's leftmost match; `re.findall` returns
// non-overlapping matches advancing past each. We reproduce that scan.

fn isPathBodyChar(ch: u8) bool {
    // [\w\-/\\.] == word | '-' | '/' | '\' | '.'
    return isWordChar(ch) or ch == '-' or ch == '/' or ch == '\\' or ch == '.';
}

fn isPathHeadChar(ch: u8) bool {
    // [\w\-.] for the second alternative's leading run.
    return isWordChar(ch) or ch == '-' or ch == '.';
}

/// Try to match a path token starting exactly at `i`. Returns end index or null.
/// Mirrors the two-branch alternation, branch 1 (prefix-anchored) first since
/// the regex lists it first and Python tries alternatives left-to-right.
fn matchPathAt(s: []const u8, i: usize) ?usize {
    // Branch 1: (?:\./|\.\./|/|[A-Za-z]:\\) [\w\-/\\.]+
    var prefix_len: usize = 0;
    if (std.mem.startsWith(u8, s[i..], "../")) {
        prefix_len = 3;
    } else if (std.mem.startsWith(u8, s[i..], "./")) {
        prefix_len = 2;
    } else if (s[i] == '/') {
        prefix_len = 1;
    } else if (i + 2 < s.len and isAlpha(s[i]) and s[i + 1] == ':' and s[i + 2] == '\\') {
        prefix_len = 3;
    }
    if (prefix_len > 0) {
        var j = i + prefix_len;
        const body_start = j;
        while (j < s.len and isPathBodyChar(s[j])) j += 1;
        if (j > body_start) return j; // [...]+ requires >=1 body char
        // Prefix matched but no body char → branch-1 fails at this position.
    }

    // Branch 2: [\w\-.]+ [/\\] [\w\-/\\.]+
    var j = i;
    const head_start = j;
    while (j < s.len and isPathHeadChar(s[j])) j += 1;
    if (j == head_start) return null; // need >=1 head char
    if (j >= s.len or (s[j] != '/' and s[j] != '\\')) return null; // need a separator
    j += 1; // consume the separator
    const tail_start = j;
    while (j < s.len and isPathBodyChar(s[j])) j += 1;
    if (j == tail_start) return null; // need >=1 tail char
    return j;
}

/// Collect the distinct path matches (non-overlapping, leftmost), into `set`.
fn collectPaths(gpa: Allocator, text: []const u8, set: *std.StringHashMap(void)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (matchPathAt(text, i)) |end| {
            const tok = text[i..end];
            if (!set.contains(tok)) {
                const owned = try gpa.dupe(u8, tok);
                errdefer gpa.free(owned);
                try set.put(owned, {});
            }
            i = end;
            continue;
        }
        i += 1;
    }
}

// ── Bullets ─────────────────────────────────────────────────────────────────
// BULLET_REGEX = ^\s*[-*+]\s+  (re.MULTILINE) → count.
// Per Python MULTILINE, `^` matches at start of each line; `\s*` can span the
// newline-stripped indentation. We scan line by line, but note `\s*` in Python
// can also consume leading blank lines preceding the bullet because `\s`
// includes '\n'. In practice findall over MULTILINE anchors each `^` per line
// and `\s*` then eats same-line indentation; cross-line consumption does not
// create extra matches because findall is non-overlapping and `[-*+]\s+` still
// needs a bullet char. We count one per qualifying line — validated by the
// differential against representative inputs.

fn countBullets(text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        var i: usize = 0;
        while (i < line.len and isSpace(line[i])) i += 1; // \s*
        if (i >= line.len) continue;
        if (line[i] != '-' and line[i] != '*' and line[i] != '+') continue; // [-*+]
        i += 1;
        if (i >= line.len or !isSpace(line[i])) continue; // \s+ (>=1)
        count += 1;
    }
    return count;
}

// ── Inline code ─────────────────────────────────────────────────────────────
// extract_inline_codes:
//   1. strip ^```...^``` blocks (MULTILINE DOTALL) and ^~~~...^~~~ blocks
//   2. findall `([^`]+)`  → list (multiset / Counter)
// Step 1 removes fenced regions; the remaining inline `code` spans are counted.
// We reproduce the fence-stripping with the same line-anchored, non-greedy
// matching the Python `re.sub(r"^```[\s\S]*?^```", "", flags=MULTILINE)` uses.

/// Remove the first occurrence of a same-marker fenced region that opens with a
/// line STARTING with `marker` (exactly, no indent — Python's `^```` is column
/// 0) and closes with the next line STARTING with `marker`. Returns true if a
/// region was removed; writes the result to `out` (cleared first).
fn stripFences(gpa: Allocator, text: []const u8, marker: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    // Python applies re.sub globally; emulate: walk lines, when a line starts
    // with `marker` (at column 0), drop lines until (and including) the next line
    // starting with `marker`. Mirrors non-greedy ^```[\s\S]*?^``` repeated.
    out.clearRetainingCapacity();
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var in_fence = false;
    while (it.next()) |line| {
        // Reconstruct the original '\n' separators between emitted lines.
        const starts = std.mem.startsWith(u8, line, marker);
        if (!in_fence) {
            if (starts) {
                in_fence = true;
                // Drop the opening line; do NOT emit it. Also do not emit a
                // separator for it.
                continue;
            }
            if (!first) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
            first = false;
        } else {
            // Inside a fence: the closing line is the next one starting with
            // marker; drop it too, then resume.
            if (starts) {
                in_fence = false;
            }
            // Drop every line while in_fence (and the closing line).
            continue;
        }
    }
}

/// Collect inline-code tokens into a multiset (token → count). Owned keys.
fn collectInlineCodes(gpa: Allocator, text: []const u8, counts: *std.StringHashMap(usize)) Allocator.Error!void {
    // Strip ``` fences then ~~~ fences, sequentially, like the two re.sub calls.
    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(gpa);
    try stripFences(gpa, text, "```", &buf1);

    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    try stripFences(gpa, buf1.items, "~~~", &buf2);

    const s = buf2.items;
    // findall `([^`]+)` — non-overlapping: open backtick, capture run of
    // non-backtick (>=1), close backtick. Advance past the closing backtick.
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        // opening backtick at i; capture [^`]+ then a closing backtick.
        var j = i + 1;
        while (j < s.len and s[j] != '`') j += 1;
        if (j < s.len and j > i + 1) {
            const tok = s[i + 1 .. j];
            const gop = try counts.getOrPut(tok);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, tok);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
            i = j + 1; // advance past the closing backtick
        } else {
            // `` (empty) or unterminated → the opening backtick is consumed as a
            // literal; Python's `([^`]+)` requires >=1 inner char, and an empty
            // `` matches nothing here. Advance by 1 to keep scanning.
            i += 1;
        }
    }
}

// ── Set / multiset helpers ──────────────────────────────────────────────────

fn freeSet(gpa: Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |e| gpa.free(e.key_ptr.*);
    set.deinit();
}

fn freeCounts(gpa: Allocator, counts: *std.StringHashMap(usize)) void {
    var it = counts.iterator();
    while (it.next()) |e| gpa.free(e.key_ptr.*);
    counts.deinit();
}

fn setsEqual(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| if (!b.contains(e.key_ptr.*)) return false;
    return true;
}

fn countsEqual(a: *const std.StringHashMap(usize), b: *const std.StringHashMap(usize)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const bv = b.get(e.key_ptr.*) orelse return false;
        if (bv != e.value_ptr.*) return false;
    }
    return true;
}

/// Sorted slice of the keys in `a` that are NOT in `b` (the Python `a - b` set
/// difference, sorted for deterministic rendering). Caller frees the returned
/// slice (keys are borrowed from `a`).
fn sortedDiff(gpa: Allocator, a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = a.iterator();
    while (it.next()) |e| {
        if (!b.contains(e.key_ptr.*)) try list.append(gpa, e.key_ptr.*);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Format a Python-style set literal of sorted strings: `{'a', 'b'}` or `set()`
/// when empty. Matches Python's repr of a set of str well enough for a canonical
/// (sorted) comparison; the differential harness normalizes the Python side to
/// the same sorted form.
fn formatStrSet(gpa: Allocator, items: []const []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (items.len == 0) {
        try out.appendSlice(gpa, "set()");
        return;
    }
    try out.append(gpa, '{');
    for (items, 0..) |s, idx| {
        if (idx > 0) try out.appendSlice(gpa, ", ");
        try out.append(gpa, '\'');
        try out.appendSlice(gpa, s);
        try out.append(gpa, '\'');
    }
    try out.append(gpa, '}');
}

// ── Validators ──────────────────────────────────────────────────────────────

fn validateHeadings(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    var h1 = try extractHeadings(gpa, orig);
    defer h1.deinit(gpa);
    var h2 = try extractHeadings(gpa, comp);
    defer h2.deinit(gpa);

    if (h1.items.len != h2.items.len) {
        const msg = try std.fmt.allocPrint(gpa, "Heading count mismatch: {d} vs {d}", .{ h1.items.len, h2.items.len });
        try result.addError(gpa, msg);
    }
    if (!headingsEqual(h1.items, h2.items)) {
        try result.addWarning(gpa, try gpa.dupe(u8, "Heading text/order changed"));
    }
}

fn validateCodeBlocks(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    var c1 = try extractCodeBlocks(gpa, orig);
    defer {
        for (c1.items) |b| gpa.free(b);
        c1.deinit(gpa);
    }
    var c2 = try extractCodeBlocks(gpa, comp);
    defer {
        for (c2.items) |b| gpa.free(b);
        c2.deinit(gpa);
    }
    if (!codeBlocksEqual(c1.items, c2.items)) {
        try result.addError(gpa, try gpa.dupe(u8, "Code blocks not preserved exactly"));
    }
}

fn validateUrls(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    var url1 = std.StringHashMap(void).init(gpa);
    defer freeSet(gpa, &url1);
    var url2 = std.StringHashMap(void).init(gpa);
    defer freeSet(gpa, &url2);
    try collectUrls(gpa, orig, &url1);
    try collectUrls(gpa, comp, &url2);

    if (!setsEqual(&url1, &url2)) {
        const lost = try sortedDiff(gpa, &url1, &url2);
        defer gpa.free(lost);
        const added = try sortedDiff(gpa, &url2, &url1);
        defer gpa.free(added);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.appendSlice(gpa, "URL mismatch: lost=");
        try formatStrSet(gpa, lost, &buf);
        try buf.appendSlice(gpa, ", added=");
        try formatStrSet(gpa, added, &buf);
        try result.addError(gpa, try buf.toOwnedSlice(gpa));
    }
}

fn validatePaths(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    var p1 = std.StringHashMap(void).init(gpa);
    defer freeSet(gpa, &p1);
    var p2 = std.StringHashMap(void).init(gpa);
    defer freeSet(gpa, &p2);
    try collectPaths(gpa, orig, &p1);
    try collectPaths(gpa, comp, &p2);

    if (!setsEqual(&p1, &p2)) {
        const lost = try sortedDiff(gpa, &p1, &p2);
        defer gpa.free(lost);
        const added = try sortedDiff(gpa, &p2, &p1);
        defer gpa.free(added);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.appendSlice(gpa, "Path mismatch: lost=");
        try formatStrSet(gpa, lost, &buf);
        try buf.appendSlice(gpa, ", added=");
        try formatStrSet(gpa, added, &buf);
        try result.addWarning(gpa, try buf.toOwnedSlice(gpa));
    }
}

fn validateBullets(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    const b1 = countBullets(orig);
    const b2 = countBullets(comp);
    if (b1 == 0) return;
    // diff = abs(b1 - b2) / b1  (Python float division)
    const fb1: f64 = @floatFromInt(b1);
    const absdiff: f64 = @floatFromInt(if (b1 > b2) b1 - b2 else b2 - b1);
    const diff = absdiff / fb1;
    if (diff > 0.15) {
        const msg = try std.fmt.allocPrint(gpa, "Bullet count changed too much: {d} -> {d}", .{ b1, b2 });
        try result.addWarning(gpa, msg);
    }
}

fn validateInlineCodes(gpa: Allocator, orig: []const u8, comp: []const u8, result: *Result) Allocator.Error!void {
    var c1 = std.StringHashMap(usize).init(gpa);
    defer freeCounts(gpa, &c1);
    var c2 = std.StringHashMap(usize).init(gpa);
    defer freeCounts(gpa, &c2);
    try collectInlineCodes(gpa, orig, &c1);
    try collectInlineCodes(gpa, comp, &c2);

    if (countsEqual(&c1, &c2)) return;

    // Build the `lost` set: keys in c1 not in c2, PLUS keys present in c2 with a
    // lower count, rendered as "code (lost N of M occurrences)". And the `added`
    // set: keys in c2 not in c1.
    var lost_list: std.ArrayList([]const u8) = .empty; // owned entries (must free)
    defer {
        for (lost_list.items) |m| gpa.free(m);
        lost_list.deinit(gpa);
    }
    var added_list: std.ArrayList([]const u8) = .empty; // borrowed from c2 keys
    defer added_list.deinit(gpa);

    // lost = set(c1) - set(c2)  (rendered as bare tokens)
    {
        var it = c1.iterator();
        while (it.next()) |e| {
            if (!c2.contains(e.key_ptr.*)) {
                try lost_list.append(gpa, try gpa.dupe(u8, e.key_ptr.*));
            }
        }
    }
    // for code,count in c1: if code in c2 and c2[code] < count → add detail line.
    {
        var it = c1.iterator();
        while (it.next()) |e| {
            const code = e.key_ptr.*;
            const count = e.value_ptr.*;
            if (c2.get(code)) |c2v| {
                if (c2v < count) {
                    const msg = try std.fmt.allocPrint(gpa, "{s} (lost {d} of {d} occurrences)", .{ code, count - c2v, count });
                    try lost_list.append(gpa, msg);
                }
            }
        }
    }
    // added = set(c2) - set(c1)
    {
        var it = c2.iterator();
        while (it.next()) |e| {
            if (!c1.contains(e.key_ptr.*)) try added_list.append(gpa, e.key_ptr.*);
        }
    }

    std.mem.sort([]const u8, lost_list.items, {}, lessThanStr);
    std.mem.sort([]const u8, added_list.items, {}, lessThanStr);

    if (lost_list.items.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.appendSlice(gpa, "Inline code lost: ");
        try formatStrSet(gpa, lost_list.items, &buf);
        try result.addError(gpa, try buf.toOwnedSlice(gpa));
    }
    if (added_list.items.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.appendSlice(gpa, "Inline code added: ");
        try formatStrSet(gpa, added_list.items, &buf);
        try result.addWarning(gpa, try buf.toOwnedSlice(gpa));
    }
}

// ── Public entry point ──────────────────────────────────────────────────────

/// Run all six validators on the original vs compressed markdown. Returns a
/// Result the caller must deinit. Mirrors validate.py's validate(): the same
/// six checks in the same order, same error/warning classification.
pub fn validate(gpa: Allocator, orig: []const u8, comp: []const u8) Allocator.Error!Result {
    var result: Result = .{};
    errdefer result.deinit(gpa);
    try validateHeadings(gpa, orig, comp, &result);
    try validateCodeBlocks(gpa, orig, comp, &result);
    try validateUrls(gpa, orig, comp, &result);
    try validatePaths(gpa, orig, comp, &result);
    try validateBullets(gpa, orig, comp, &result);
    try validateInlineCodes(gpa, orig, comp, &result);
    return result;
}

// ── CLI ─────────────────────────────────────────────────────────────────────
// Usage: caveman-compress-validate <original> <compressed>
// Reads both files, runs validate(), prints the same report block validate.py's
// __main__ emits. Exit 1 on usage error (matches the Python `sys.exit(1)`).

const MAX_FILE_BYTES = 16 * 1024 * 1024; // generous cap; markdown docs are tiny

/// Read a file fully into an owned buffer via std.Io. validate.py reads with
/// errors="ignore" (a decode concern); we read raw bytes (markdown is ASCII/UTF-8
/// and we never decode). std.Io openFile/readPositional so the binary
/// cross-compiles. Returns error.OpenFailed on a missing/unreadable file so the
/// CLI prints usage.
fn readFile(io: std.Io, gpa: Allocator, path: []const u8) ![]u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.OpenFailed;
    defer f.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        var iov = [_][]u8{&buf};
        const n = f.readPositional(io, &iov, offset) catch return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + n > MAX_FILE_BYTES) return error.FileTooLarge;
        try out.appendSlice(gpa, buf[0..n]);
        offset += n;
    }
    return out.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Construct the std.Io backend once; thread it down to every FS fn. This
    // module has no common.zig dependency, so construct Threaded directly.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Collect positional argv (after argv0) into a slice — mirrors the
    // settings.zig CLI: init.args is a std.process.Args iterator, not a slice.
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    {
        var it = init.args.iterate();
        defer it.deinit();
        _ = it.skip(); // argv0
        while (it.next()) |a| {
            const owned = gpa.dupe(u8, a) catch continue;
            argv.append(gpa, owned) catch gpa.free(owned);
        }
    }

    if (argv.items.len != 2) {
        writeOut(io, "Usage: caveman-compress-validate <original> <compressed>\n");
        std.process.exit(1);
    }

    const orig = readFile(io, gpa, argv.items[0]) catch {
        writeOut(io, "Usage: caveman-compress-validate <original> <compressed>\n");
        std.process.exit(1);
    };
    defer gpa.free(orig);
    const comp = readFile(io, gpa, argv.items[1]) catch {
        writeOut(io, "Usage: caveman-compress-validate <original> <compressed>\n");
        std.process.exit(1);
    };
    defer gpa.free(comp);

    var result = try validate(gpa, orig, comp);
    defer result.deinit(gpa);

    const block = try result.render(gpa);
    defer gpa.free(block);
    writeOut(io, block);
}

/// Write to stdout through std.Io. Stdout is a stream (not seekable), so use the
/// portable streaming write off std.Io.File.stdout() rather than a raw libc
/// c.write(1, …). On Windows the libc write() fd arg is a pointer type
/// (fd_t == *anyopaque), so the literal `1` fails the x86_64-windows-gnu
/// cross-compile; the std.Io path resolves stdout from the PEB on Windows and
/// STDOUT_FILENO on POSIX. Silent on anomaly, matching the prior libc behavior.
fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────────────
// Mirror the behavior validate.py exercises. The Python file has no formal
// __main__ test block beyond the CLI; these tests pin each extractor + validator
// to the Python semantics, and the differential harness (validate_diff.py)
// cross-checks the whole pipeline on shared fixtures.

const testing = std.testing;

test "headings: count + text equality" {
    const gpa = testing.allocator;
    {
        var h = try extractHeadings(gpa, "# Title\n## Sub\ntext\n### Deep");
        defer h.deinit(gpa);
        try testing.expectEqual(@as(usize, 3), h.items.len);
        try testing.expectEqualStrings("#", h.items[0].level);
        try testing.expectEqualStrings("Title", h.items[0].title);
        try testing.expectEqualStrings("##", h.items[1].level);
        try testing.expectEqualStrings("Sub", h.items[1].title);
        try testing.expectEqualStrings("###", h.items[2].level);
        try testing.expectEqualStrings("Deep", h.items[2].title);
    }
    // 7 hashes is not a heading (#{1,6} then \s).
    {
        var h = try extractHeadings(gpa, "####### TooDeep\n#NoSpace");
        defer h.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), h.items.len);
    }
}

test "validateHeadings: count mismatch is error, reorder is warning" {
    const gpa = testing.allocator;
    {
        var r = try validate(gpa, "# A\n## B", "# A");
        defer r.deinit(gpa);
        try testing.expect(!r.is_valid);
        try testing.expect(r.errors.items.len >= 1);
        try testing.expectEqualStrings("Heading count mismatch: 2 vs 1", r.errors.items[0]);
    }
    {
        // Same count, different title → warning, still valid (no error from this check).
        var r = try validate(gpa, "# A\n## B", "# A\n## C");
        defer r.deinit(gpa);
        var saw_warning = false;
        for (r.warnings.items) |w| {
            if (std.mem.eql(u8, w, "Heading text/order changed")) saw_warning = true;
        }
        try testing.expect(saw_warning);
    }
}

test "code blocks: extract + variable-length + nested" {
    const gpa = testing.allocator;
    {
        var b = try extractCodeBlocks(gpa, "before\n```js\nlet x = 1;\n```\nafter");
        defer {
            for (b.items) |x| gpa.free(x);
            b.deinit(gpa);
        }
        try testing.expectEqual(@as(usize, 1), b.items.len);
        try testing.expectEqualStrings("```js\nlet x = 1;\n```", b.items[0]);
    }
    {
        // Nested: outer 4-backtick wraps inner 3-backtick. Closing must be >= 4.
        const txt = "````\n```\ninner\n```\n````";
        var b = try extractCodeBlocks(gpa, txt);
        defer {
            for (b.items) |x| gpa.free(x);
            b.deinit(gpa);
        }
        try testing.expectEqual(@as(usize, 1), b.items.len);
        try testing.expectEqualStrings(txt, b.items[0]);
    }
    {
        // Unclosed fence → skipped (no block).
        var b = try extractCodeBlocks(gpa, "```\nno close here");
        defer {
            for (b.items) |x| gpa.free(x);
            b.deinit(gpa);
        }
        try testing.expectEqual(@as(usize, 0), b.items.len);
    }
}

test "validateCodeBlocks: altered code is error" {
    const gpa = testing.allocator;
    var r = try validate(gpa, "```\nA\n```", "```\nB\n```");
    defer r.deinit(gpa);
    try testing.expect(!r.is_valid);
    var saw = false;
    for (r.errors.items) |e| {
        if (std.mem.eql(u8, e, "Code blocks not preserved exactly")) saw = true;
    }
    try testing.expect(saw);
}

test "urls: set + mismatch error" {
    const gpa = testing.allocator;
    {
        var set = std.StringHashMap(void).init(gpa);
        defer freeSet(gpa, &set);
        try collectUrls(gpa, "see https://a.com/x and http://b.org (https://a.com/x dup)", &set);
        try testing.expectEqual(@as(usize, 2), set.count());
        try testing.expect(set.contains("https://a.com/x"));
        try testing.expect(set.contains("http://b.org"));
    }
    {
        var r = try validate(gpa, "go https://keep.me here", "go nowhere here");
        defer r.deinit(gpa);
        try testing.expect(!r.is_valid);
        var saw = false;
        for (r.errors.items) |e| {
            if (std.mem.startsWith(u8, e, "URL mismatch:")) saw = true;
        }
        try testing.expect(saw);
    }
}

test "paths: set + mismatch warning" {
    const gpa = testing.allocator;
    {
        var set = std.StringHashMap(void).init(gpa);
        defer freeSet(gpa, &set);
        try collectPaths(gpa, "edit src/main.zig and ./rel and /abs/path", &set);
        try testing.expect(set.contains("src/main.zig"));
        try testing.expect(set.contains("./rel"));
        try testing.expect(set.contains("/abs/path"));
    }
    {
        var r = try validate(gpa, "open src/a.zig", "open nothing");
        defer r.deinit(gpa);
        // Path drift is a WARNING — still valid.
        try testing.expect(r.is_valid);
        var saw = false;
        for (r.warnings.items) |w| {
            if (std.mem.startsWith(u8, w, "Path mismatch:")) saw = true;
        }
        try testing.expect(saw);
    }
}

test "bullets: count + 15% tolerance" {
    try testing.expectEqual(@as(usize, 3), countBullets("- a\n* b\n  + c\nnot a bullet"));
    const gpa = testing.allocator;
    {
        // 10 bullets → 8 bullets = 20% drop > 15% → warning.
        const orig = "- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n- 7\n- 8\n- 9\n- 10";
        const comp = "- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n- 7\n- 8";
        var r = try validate(gpa, orig, comp);
        defer r.deinit(gpa);
        var saw = false;
        for (r.warnings.items) |w| {
            if (std.mem.startsWith(u8, w, "Bullet count changed too much:")) saw = true;
        }
        try testing.expect(saw);
    }
    {
        // 10 → 9 = 10% <= 15% → no warning.
        const orig = "- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n- 7\n- 8\n- 9\n- 10";
        const comp = "- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n- 7\n- 8\n- 9";
        var r = try validate(gpa, orig, comp);
        defer r.deinit(gpa);
        for (r.warnings.items) |w| {
            try testing.expect(!std.mem.startsWith(u8, w, "Bullet count changed too much:"));
        }
    }
}

test "inline code: multiset, fence stripping, lost is error" {
    const gpa = testing.allocator;
    {
        // Fenced ``` region must be stripped before inline scan.
        var counts = std.StringHashMap(usize).init(gpa);
        defer freeCounts(gpa, &counts);
        try collectInlineCodes(gpa, "use `foo` and `foo`\n```\n`not_inline`\n```\n`bar`", &counts);
        try testing.expectEqual(@as(usize, 2), counts.get("foo").?);
        try testing.expectEqual(@as(usize, 1), counts.get("bar").?);
        try testing.expect(counts.get("not_inline") == null);
    }
    {
        var r = try validate(gpa, "keep `token` here", "keep token here");
        defer r.deinit(gpa);
        try testing.expect(!r.is_valid);
        var saw = false;
        for (r.errors.items) |e| {
            if (std.mem.startsWith(u8, e, "Inline code lost:")) saw = true;
        }
        try testing.expect(saw);
    }
    {
        // Dropped occurrence (2 → 1) is reported with the "(lost N of M)" detail.
        var r = try validate(gpa, "`x` `x`", "`x`");
        defer r.deinit(gpa);
        var saw_detail = false;
        for (r.errors.items) |e| {
            if (std.mem.indexOf(u8, e, "x (lost 1 of 2 occurrences)") != null) saw_detail = true;
        }
        try testing.expect(saw_detail);
    }
    {
        // Added inline code is a WARNING, not an error.
        var r = try validate(gpa, "plain", "now `added`");
        defer r.deinit(gpa);
        try testing.expect(r.is_valid);
        var saw = false;
        for (r.warnings.items) |w| {
            if (std.mem.startsWith(u8, w, "Inline code added:")) saw = true;
        }
        try testing.expect(saw);
    }
}

test "render: clean run reports Valid: True" {
    const gpa = testing.allocator;
    var r = try validate(gpa, "# H\n- b\n`c` https://u.co src/x.zig", "# H\n- b\n`c` https://u.co src/x.zig");
    defer r.deinit(gpa);
    try testing.expect(r.is_valid);
    const block = try r.render(gpa);
    defer gpa.free(block);
    try testing.expectEqualStrings("\nValid: True\n", block);
}

test "render: errors + warnings sections" {
    const gpa = testing.allocator;
    var r = try validate(gpa, "# A\n## B\n`tok`", "# A\n`tok` extra `tok`");
    defer r.deinit(gpa);
    const block = try r.render(gpa);
    defer gpa.free(block);
    try testing.expect(std.mem.startsWith(u8, block, "\nValid: False\n"));
    try testing.expect(std.mem.indexOf(u8, block, "\nErrors:\n") != null);
}
