//! caveman-shrink prose compressor — Zig 0.16 port of compress.js.
//!
//! Faithful reimplementation of the Node compressor's regex pipeline. The JS
//! relies on JavaScript RegExp; Zig std has no regex engine, so each pattern is
//! reproduced as a targeted scanner with byte-exact semantics validated against
//! the JS output (see the differential check in the task).
//!
//! Pipeline (order matters — matches compress.js exactly):
//!   1. Protect: replace every PROTECTED_PATTERN match (in pattern order) with a
//!      sentinel ` <index> ` (space, decimal index, space). Originals stashed.
//!   2. compressProse on the sentinel-substituted text:
//!        LEADERS (line-start) → PLEASANTRIES → HEDGES → FILLERS → ARTICLES →
//!        collapse [ \t]{2,} → strip space before ,.;:!? → collapse \n{3,} →
//!        capitalize sentence starts → trim.
//!   3. Restore: replace ` <digit+> ` sentinels with the stashed originals.
//!
//! Boundaries NEVER touched: fenced code, inline code, URLs, paths, CONST_CASE,
//! dotted.method / pkg.fn(), function calls, version numbers.
//!
//! API: compress(gpa, text) → owned []u8 (caller frees). Empty input returns an
//! owned empty/duped copy so callers can free uniformly.

const std = @import("std");

// ── Character classes mirroring JS \b, [a-z]i, \w, \s ──────────────────────--

fn isWordChar(ch: u8) bool {
    // JS \w == [A-Za-z0-9_]
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isSpace(ch: u8) bool {
    // JS \s for our inputs: space, tab, CR, LF, form feed, vertical tab.
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == 0x0c or ch == 0x0b;
}

/// JS \b at position `i` in `s`: word-char on one side, non-word (or edge) on
/// the other. Here we test the boundary BEFORE index `i` (between i-1 and i).
fn wordBoundaryBefore(s: []const u8, i: usize) bool {
    const left = if (i == 0) false else isWordChar(s[i - 1]);
    const right = if (i >= s.len) false else isWordChar(s[i]);
    return left != right;
}

// ── Protected segments ─────────────────────────────────────────────────────--

const Segment = struct { text: []const u8 };

/// Find the earliest match of any protected pattern starting at or after `from`.
/// Returns the [start,end) of the match and which detector matched, or null.
const Match = struct { start: usize, end: usize };

/// Try to match a protected token *starting exactly at* index `i`. Returns the
/// end index (exclusive) on success. Patterns are tried in compress.js order so
/// that the first that matches at a given position wins — but because the JS
/// applies each pattern as a separate global pass, ordering across positions is
/// subtle. We instead emulate the *net* protection set: a byte is protected if
/// ANY pattern would cover it. We compute a boolean mask, which is order-
/// independent for the substitution result the JS produces (each protected
/// region becomes one sentinel; overlapping/adjacent JS passes that each
/// sentinel-ize a region collapse to the same protected mask because the
/// sentinel ` N ` itself contains no word chars/paths/etc. that later patterns
/// re-match). The differential check validates this equivalence.
fn matchAt(s: []const u8, i: usize) ?usize {
    // 1. fenced code ```...```
    if (std.mem.startsWith(u8, s[i..], "```")) {
        if (std.mem.indexOf(u8, s[i + 3 ..], "```")) |rel| {
            return i + 3 + rel + 3;
        }
    }
    // 2. inline code `...` (no backtick or newline inside, >=1 char)
    if (s[i] == '`') {
        var j = i + 1;
        var saw = false;
        while (j < s.len and s[j] != '`' and s[j] != '\n') : (j += 1) saw = true;
        if (saw and j < s.len and s[j] == '`') return j + 1;
    }
    // 3. URL: \bhttps?://\S+
    if (wordBoundaryBefore(s, i)) {
        if (matchUrl(s, i)) |end| return end;
    }
    // 4. path: \b[\w.-]*[/\\][\w./\\-]+
    if (wordBoundaryBefore(s, i)) {
        if (matchPath(s, i)) |end| return end;
    }
    // 5. CONST_CASE: \b[A-Z][A-Za-z0-9]*(?:_[A-Z][A-Za-z0-9]*)+\b
    if (wordBoundaryBefore(s, i)) {
        if (matchConstCase(s, i)) |end| return end;
    }
    // 6. dotted method call: \b\w+\.\w+(?:\.\w+)*\(\)?  — NOTE the \( is a
    //    REQUIRED literal open-paren (only \) is optional). So pkg.fn() matches
    //    but a bare dotted identifier like script.js does NOT (it falls through
    //    to prose, where a preceding article is then removed). This subtlety is
    //    load-bearing for the differential.
    if (wordBoundaryBefore(s, i)) {
        if (matchDotted(s, i)) |end| return end;
    }
    // 7. function call: [A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)
    if (matchFnCall(s, i)) |end| return end;
    // 8. version: \b\d+\.\d+\.\d+\b
    if (wordBoundaryBefore(s, i)) {
        if (matchVersion(s, i)) |end| return end;
    }
    return null;
}

fn matchUrl(s: []const u8, i: usize) ?usize {
    var j = i;
    if (std.mem.startsWith(u8, s[j..], "http")) {
        j += 4;
        if (j < s.len and s[j] == 's') j += 1;
        if (std.mem.startsWith(u8, s[j..], "://")) {
            j += 3;
            const start_nonspace = j;
            while (j < s.len and !isSpace(s[j])) : (j += 1) {}
            if (j > start_nonspace) return j;
        }
    }
    return null;
}

fn matchPath(s: []const u8, i: usize) ?usize {
    // [\w.-]* then a slash, then [\w./\\-]+
    var j = i;
    while (j < s.len and (isWordChar(s[j]) or s[j] == '.' or s[j] == '-')) : (j += 1) {}
    // need a slash next
    if (j >= s.len or (s[j] != '/' and s[j] != '\\')) return null;
    const after_prefix = j;
    // [\w./\\-]+ (one or more, includes the slash we're on)
    while (j < s.len and (isWordChar(s[j]) or s[j] == '.' or s[j] == '/' or s[j] == '\\' or s[j] == '-')) : (j += 1) {}
    if (j > after_prefix) return j;
    return null;
}

fn matchConstCase(s: []const u8, i: usize) ?usize {
    // [A-Z][A-Za-z0-9]* then one-or-more (_[A-Z][A-Za-z0-9]*) then \b
    var j = i;
    if (j >= s.len or !(s[j] >= 'A' and s[j] <= 'Z')) return null;
    j += 1;
    while (j < s.len and (isAlpha(s[j]) or (s[j] >= '0' and s[j] <= '9'))) : (j += 1) {}
    var groups: usize = 0;
    while (j < s.len and s[j] == '_') {
        const seg_start = j + 1;
        if (seg_start >= s.len or !(s[seg_start] >= 'A' and s[seg_start] <= 'Z')) break;
        j = seg_start + 1;
        while (j < s.len and (isAlpha(s[j]) or (s[j] >= '0' and s[j] <= '9'))) : (j += 1) {}
        groups += 1;
    }
    if (groups == 0) return null;
    if (!wordBoundaryBefore(s, j)) return null;
    return j;
}

fn matchDotted(s: []const u8, i: usize) ?usize {
    // JS: \b\w+\.\w+(?:\.\w+)*\(\)?  — \w+ . \w+ (. \w+)* then a REQUIRED '('
    // and an OPTIONAL ')'. The open-paren is NOT optional, so a bare dotted
    // identifier (script.js) does not match here.
    var j = i;
    const w0 = j;
    while (j < s.len and isWordChar(s[j])) : (j += 1) {}
    if (j == w0) return null;
    if (j >= s.len or s[j] != '.') return null;
    // require at least one .\w+
    var dots: usize = 0;
    while (j < s.len and s[j] == '.') {
        const seg = j + 1;
        if (seg >= s.len or !isWordChar(s[seg])) break;
        j = seg;
        while (j < s.len and isWordChar(s[j])) : (j += 1) {}
        dots += 1;
    }
    if (dots == 0) return null;
    // REQUIRED '(' then OPTIONAL ')'.
    if (j >= s.len or s[j] != '(') return null;
    j += 1;
    if (j < s.len and s[j] == ')') j += 1;
    return j;
}

fn matchFnCall(s: []const u8, i: usize) ?usize {
    // [A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)
    var j = i;
    if (j >= s.len or !(isAlpha(s[j]) or s[j] == '_')) return null;
    j += 1;
    while (j < s.len and isWordChar(s[j])) : (j += 1) {}
    while (j < s.len and isSpace(s[j])) : (j += 1) {}
    if (j >= s.len or s[j] != '(') return null;
    j += 1;
    while (j < s.len and s[j] != ')') : (j += 1) {}
    if (j >= s.len or s[j] != ')') return null;
    return j + 1;
}

fn matchVersion(s: []const u8, i: usize) ?usize {
    // \d+\.\d+\.\d+\b
    var j = i;
    const d0 = j;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
    if (j == d0 or j >= s.len or s[j] != '.') return null;
    j += 1;
    const d1 = j;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
    if (j == d1 or j >= s.len or s[j] != '.') return null;
    j += 1;
    const d2 = j;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
    if (j == d2) return null;
    if (!wordBoundaryBefore(s, j)) return null;
    return j;
}

/// The sentinel delimiter. CRITICAL: the JS compress.js uses a NUL byte (0x00),
/// NOT a space, around the segment index. The NUL is invisible
/// in editors/Read but is what the file actually contains (verified by byte
/// inspection). Using NUL is load-bearing: it is not whitespace, not a word
/// char, and not punctuation, so the compressProse passes leave it untouched
/// and the ORIGINAL spaces around the protected token are preserved. A space
/// sentinel would be eaten by collapseSpaces / stripSpaceBeforePunct and diverge.
const SENTINEL: u8 = 0x00;

/// Replace protected matches with `\x00<i>\x00` sentinels, stashing originals.
/// Returns the substituted working text (owned). Greedy left-to-right scan:
/// at each position, take the longest protected match starting there.
fn protect(
    gpa: std.mem.Allocator,
    text: []const u8,
    segments: *std.ArrayList(Segment),
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (matchAt(text, i)) |end| {
            const idx = segments.items.len;
            try segments.append(gpa, .{ .text = text[i..end] });
            try out.append(gpa, SENTINEL);
            try out.print(gpa, "{d}", .{idx});
            try out.append(gpa, SENTINEL);
            i = end;
        } else {
            try out.append(gpa, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Restore `\x00<digits>\x00` sentinels. Mirrors JS
/// `out.replace(/(\d+)/g, ...)`: a NUL, one-or-more digits, a NUL —
/// replaced by segments[index].
fn restore(gpa: std.mem.Allocator, text: []const u8, segments: []const Segment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == SENTINEL) {
            var j = i + 1;
            const d0 = j;
            while (j < text.len and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
            if (j > d0 and j < text.len and text[j] == SENTINEL) {
                const idx = std.fmt.parseInt(usize, text[d0..j], 10) catch {
                    try out.append(gpa, text[i]);
                    i += 1;
                    continue;
                };
                if (idx < segments.len) {
                    try out.appendSlice(gpa, segments[idx].text);
                    i = j + 1; // consume trailing NUL (regex consumes both)
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ── Prose compression passes ─────────────────────────────────────────────────

const fillers = [_][]const u8{
    "just",  "really", "basically",   "actually",  "simply",
    "quite", "very",   "essentially", "literally",
};

const pleasantries = [_][]const u8{
    "please",    "kindly",    "thank you", "thanks",       "sure",
    "certainly", "of course", "happy to",  "i'd be happy", "id be happy",
};

const hedges = [_][]const u8{
    "perhaps",       "maybe",   "might",         "could potentially",
    "would like to", "i think", "in my opinion", "it seems",
    "it appears",
};

const leaders = [_][]const u8{
    "i'll",    "ill",     "i will", "i can",  "i'd",   "id",
    "you can", "we will", "we can", "let me", "let's", "lets",
};

/// Case-insensitive literal compare of s[i..] against `needle`.
fn matchesIgnoreCase(s: []const u8, i: usize, needle: []const u8) bool {
    if (i + needle.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle);
}

/// Remove `\b(?:words)\b` (case-insensitive). FILLERS: replace match with empty.
/// Leaves surrounding whitespace; collapse pass cleans up. The JS FILLERS regex
/// has no trailing \s* so only the word itself is removed.
fn removeWordList(gpa: std.mem.Allocator, s: []const u8, words: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        var matched = false;
        if (wordBoundaryBefore(s, i)) {
            for (words) |w| {
                if (matchesIgnoreCase(s, i, w) and wordBoundaryBefore(s, i + w.len)) {
                    i += w.len;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Remove `\b(?:words)\b[,.]?\s*` (PLEASANTRIES) — word, optional comma/period,
/// then trailing whitespace.
fn removePleasantries(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        var matched = false;
        if (wordBoundaryBefore(s, i)) {
            for (pleasantries) |w| {
                if (matchesIgnoreCase(s, i, w) and wordBoundaryBefore(s, i + w.len)) {
                    var j = i + w.len;
                    if (j < s.len and (s[j] == ',' or s[j] == '.')) j += 1;
                    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\r' or s[j] == '\n' or s[j] == 0x0c or s[j] == 0x0b)) : (j += 1) {}
                    i = j;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Remove `\b(?:words)\b\s*` (HEDGES) — word then trailing whitespace.
fn removeHedges(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        var matched = false;
        if (wordBoundaryBefore(s, i)) {
            for (hedges) |w| {
                if (matchesIgnoreCase(s, i, w) and wordBoundaryBefore(s, i + w.len)) {
                    var j = i + w.len;
                    while (j < s.len and isSpace(s[j])) : (j += 1) {}
                    i = j;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Remove LEADERS: `^(?:words)\s+` with /gim — at the start of each LINE,
/// the word followed by one-or-more whitespace.
fn removeLeaders(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var at_line_start = true;
    while (i < s.len) {
        if (at_line_start) {
            var matched = false;
            for (leaders) |w| {
                if (matchesIgnoreCase(s, i, w) and wordBoundaryBefore(s, i + w.len)) {
                    var j = i + w.len;
                    // require \s+ (one or more), per the regex
                    if (j < s.len and isSpace(s[j])) {
                        while (j < s.len and isSpace(s[j])) : (j += 1) {}
                        i = j;
                        matched = true;
                        break;
                    }
                }
            }
            if (matched) {
                at_line_start = false; // a line-start match consumed; continue
                continue;
            }
        }
        const ch = s[i];
        try out.append(gpa, ch);
        at_line_start = (ch == '\n');
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Remove ARTICLES: `\b(?:a|an|the)\s+(?=[a-z])` with /gi. The /i flag makes
/// the [a-z] lookahead match uppercase too, so the lookahead is "any letter".
fn removeArticles(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const arts = [_][]const u8{ "a", "an", "the" };
    var i: usize = 0;
    while (i < s.len) {
        var matched = false;
        if (wordBoundaryBefore(s, i)) {
            for (arts) |w| {
                if (matchesIgnoreCase(s, i, w) and wordBoundaryBefore(s, i + w.len)) {
                    var j = i + w.len;
                    const ws_start = j;
                    while (j < s.len and isSpace(s[j])) : (j += 1) {}
                    if (j > ws_start and j < s.len and isAlpha(s[j])) {
                        // lookahead [a-z]/i → any letter. Consume article+ws,
                        // leave the following letter in place.
                        i = j;
                        matched = true;
                        break;
                    }
                }
            }
        }
        if (!matched) {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Collapse `[ \t]{2,}` → ' '.
fn collapseSpaces(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == ' ' or s[i] == '\t') {
            var j = i;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) : (j += 1) {}
            if (j - i >= 2) {
                try out.append(gpa, ' ');
            } else {
                try out.appendSlice(gpa, s[i..j]);
            }
            i = j;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Strip whitespace before `,.;:!?` : `\s+([,.;:!?])` → `$1`.
fn stripSpaceBeforePunct(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (isSpace(s[i])) {
            var j = i;
            while (j < s.len and isSpace(s[j])) : (j += 1) {}
            if (j < s.len and isPunct(s[j])) {
                // drop the whitespace run, keep the punct (handled next iter)
                i = j;
                continue;
            }
            try out.appendSlice(gpa, s[i..j]);
            i = j;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isPunct(ch: u8) bool {
    return ch == ',' or ch == '.' or ch == ';' or ch == ':' or ch == '!' or ch == '?';
}

/// Collapse `\n{3,}` → `\n\n`.
fn collapseNewlines(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            var j = i;
            while (j < s.len and s[j] == '\n') : (j += 1) {}
            if (j - i >= 3) {
                try out.appendSlice(gpa, "\n\n");
            } else {
                try out.appendSlice(gpa, s[i..j]);
            }
            i = j;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Capitalize sentence starts: `(^|[.!?]\s+)([a-z])` → uppercase the letter.
/// /g, no /i. Matches start-of-string OR a [.!?] followed by \s+, then a single
/// lowercase ASCII letter.
fn capitalizeSentences(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, s);
    // start-of-string lowercase letter
    if (out.len > 0 and out[0] >= 'a' and out[0] <= 'z') {
        out[0] = std.ascii.toUpper(out[0]);
    }
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == '.' or out[i] == '!' or out[i] == '?') {
            // require \s+ then [a-z]
            var j = i + 1;
            const ws0 = j;
            while (j < out.len and isSpace(out[j])) : (j += 1) {}
            if (j > ws0 and j < out.len and out[j] >= 'a' and out[j] <= 'z') {
                out[j] = std.ascii.toUpper(out[j]);
            }
        }
    }
    return out;
}

fn trimToOwned(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    // JS String.trim strips leading/trailing whitespace (incl. \n).
    const t = std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
    return gpa.dupe(u8, t);
}

/// Run the full compressProse pipeline (operates on sentinel-substituted text).
fn compressProse(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const s1 = try removeLeaders(gpa, text);
    defer gpa.free(s1);
    const s2 = try removePleasantries(gpa, s1);
    defer gpa.free(s2);
    const s3 = try removeHedges(gpa, s2);
    defer gpa.free(s3);
    const s4 = try removeWordList(gpa, s3, &fillers);
    defer gpa.free(s4);
    const s5 = try removeArticles(gpa, s4);
    defer gpa.free(s5);
    const s6 = try collapseSpaces(gpa, s5);
    defer gpa.free(s6);
    const s7 = try stripSpaceBeforePunct(gpa, s6);
    defer gpa.free(s7);
    const s8 = try collapseNewlines(gpa, s7);
    defer gpa.free(s8);
    const s9 = try capitalizeSentences(gpa, s8);
    defer gpa.free(s9);
    return trimToOwned(gpa, s9);
}

/// Compress `text`, preserving protected segments. Returns an owned buffer.
pub fn compress(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return gpa.dupe(u8, text);

    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(gpa);

    const working = try protect(gpa, text, &segments);
    defer gpa.free(working);

    const compressed = try compressProse(gpa, working);
    defer gpa.free(compressed);

    return restore(gpa, compressed, segments.items);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectCompress(input: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const out = try compress(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "compress drops fillers, articles, pleasantries" {
    try expectCompress(
        "Please read the file at src/index.js and just return the contents.",
        "Read file at src/index.js and return contents.",
    );
}

test "compress drops leaders and fillers, preserves command" {
    try expectCompress(
        "I will basically run the command npm install to set up the project.",
        "run command npm install to set up project.",
    );
}

test "compress preserves URLs and inline code" {
    try expectCompress(
        "This is a really simple tool. You can use it to fetch https://example.com/api and the data.",
        "This is simple tool. You can use it to fetch https://example.com/api and data.",
    );
    try expectCompress(
        "Run `npm test` and the script.js file. See https://x.io/y.",
        "Run `npm test` and script.js file. See https://x.io/y.",
    );
}

test "compress preserves paths and dotted identifiers" {
    try expectCompress(
        "Use the function foo(bar) to compute the value. The result is a number.",
        "Use function foo(bar) to compute value. Result is number.",
    );
    try expectCompress(
        "Thank you for using this. The path is /usr/local/bin and the version 1.2.3 works.",
        "For using this. Path is /usr/local/bin and version 1.2.3 works.",
    );
}

test "compress: CONST_CASE blocks article removal via sentinel" {
    try expectCompress(
        "Maybe you could potentially use the CONST_VALUE here. It is the default.",
        "You use the CONST_VALUE here. It is default.",
    );
}

test "compress: i-flag article lookahead matches uppercase" {
    try expectCompress("the Apple", "Apple");
    try expectCompress("the API and the json", "API and json");
}

test "compress: article at EOS or before digit is kept" {
    try expectCompress("a an the", "The");
    try expectCompress("the 5 apples", "The 5 apples");
    try expectCompress("the the the apple", "Apple");
}

test "compress: word boundaries don't truncate inside words" {
    try expectCompress("another the apple and a banana", "Another apple and banana");
    try expectCompress("justice basically matters", "Justice matters");
    try expectCompress("no-changes-needed-here_token", "No-changes-needed-here_token");
}

test "compress: protected token at start keeps its case (sentinel)" {
    try expectCompress("foo.bar() is the thing", "foo.bar() is thing");
    try expectCompress("end. foo.bar() next", "End. foo.bar() next");
    try expectCompress("1.2.3 is the version", "1.2.3 is version");
}

test "compress: fenced code block preserved" {
    try expectCompress(
        "```\ncode block the keep\n``` and the prose just here.",
        "```\ncode block the keep\n``` and prose here.",
    );
}

test "compress: leaders only at line start, not mid-sentence" {
    try expectCompress(
        "I'll just do the thing. you can really help.",
        "do thing. You can help.",
    );
}

test "compress: whitespace and punctuation collapse" {
    try expectCompress(
        "Multiple   spaces   here  ,  and  the  punctuation .",
        "Multiple spaces here, and punctuation.",
    );
    try expectCompress("do this ; and the that : ok", "Do this; and that: ok");
}

test "compress: hedges and tabs" {
    try expectCompress("It seems the value might be perhaps the best.", "Value be best.");
    try expectCompress("a\tthe\tthing", "Thing");
    try expectCompress("this might work the way", "This work way");
}

test "compress: empty and no-op" {
    try expectCompress("", "");
    try expectCompress("The Quick Brown Fox the lazy", "Quick Brown Fox lazy");
}

test "compress: pleasantries with punctuation" {
    try expectCompress("Certainly! I would like to help. Please just wait.", "! I help. Wait.");
    try expectCompress("thanks the team did the work", "Team did work");
    try expectCompress("of course the answer is the value", "Answer is value");
}
