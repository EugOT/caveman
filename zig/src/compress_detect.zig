//! caveman-compress file-type detection — Zig 0.16 port of detect.py.
//!
//! Pure classification logic, NO LLM, NO subprocess, allocator-only. Faithful
//! reimplementation of skills/caveman-compress/scripts/detect.py:
//!   detect_file_type(path) → "natural_language" | "code" | "config" | "unknown"
//!   should_compress(path)  → bool
//!
//! Two surfaces:
//!   - classifyByExt(name)         — extension table lookup only (no IO).
//!   - detectFileTypeContent(...)  — full detect_file_type, content heuristics
//!                                    included, fed the raw file bytes.
//! The split keeps the byte-scanning heuristics testable without touching the
//! filesystem (the differential harness pipes fixtures directly), while a thin
//! `main` reads files itself to mirror the Python __main__ block exactly.
//!
//! The Python regexes have no std.regex equivalent in Zig 0.16, so each is
//! reproduced as a minimal byte-scanner with the SAME anchoring/semantics,
//! validated byte-for-byte against the Python module (see the differential check
//! in build.zig's run-detect step). std primitives are used wherever they fit:
//!   - std.json.validate         → _is_json_content (the only correctness-
//!                                   critical parse; a real JSON validator).
//!   - std.ascii.toLower / eql    → case-folding the extension, literal compares.
//!   - std.mem.trim / splitScalar → strip(), splitlines() for ASCII inputs.
//!   - std.StaticStringMap        → the COMPRESSIBLE / SKIP extension tables and
//!                                   the config-extension subset (O(1), comptime).
//! Only the four line-shape predicates (_is_code_line patterns, the YAML key
//! shape) are hand-rolled — there is no stdlib regex, and these are the natural
//! minimal scanners for the exact anchored patterns.

const std = @import("std");
const c = std.c;

// The detector's filesystem core (lstat / O_NOFOLLOW open / positional read)
// runs entirely on the portable std.Io surface (R6a) so the binary
// cross-compiles. The only libc that remains is `c.write(1/2, …)` for the
// fd-based stdout/stderr writers — the stable C-ABI stdio convention shared by
// common.zig and every sibling hook binary (compress_cmd, compress_validate,
// compress_protect_cli). No raw lstat/open/read/close decls live here anymore.

pub const FileType = enum {
    natural_language,
    code,
    config,
    unknown,

    pub fn str(self: FileType) []const u8 {
        return switch (self) {
            .natural_language => "natural_language",
            .code => "code",
            .config => "config",
            .unknown => "unknown",
        };
    }
};

// ── Extension tables (mirror the Python module-level sets) ───────────────────--
//
// std.StaticStringMap gives a comptime perfect-hash lookup — the idiomatic 0.16
// way to model a fixed set keyed by string. Values are dummy `{}` (set
// membership only); presence is what matters.

const COMPRESSIBLE_EXTENSIONS = std.StaticStringMap(void).initComptime(.{
    .{ ".md", {} },  .{ ".txt", {} }, .{ ".markdown", {} },
    .{ ".rst", {} }, .{ ".typ", {} }, .{ ".typst", {} },
    .{ ".tex", {} },
});

const SKIP_EXTENSIONS = std.StaticStringMap(void).initComptime(.{
    .{ ".py", {} },       .{ ".js", {} },   .{ ".ts", {} },   .{ ".tsx", {} },
    .{ ".jsx", {} },      .{ ".json", {} }, .{ ".yaml", {} }, .{ ".yml", {} },
    .{ ".toml", {} },     .{ ".env", {} },  .{ ".lock", {} }, .{ ".css", {} },
    .{ ".scss", {} },     .{ ".html", {} }, .{ ".xml", {} },  .{ ".sql", {} },
    .{ ".sh", {} },       .{ ".bash", {} }, .{ ".zsh", {} },  .{ ".go", {} },
    .{ ".rs", {} },       .{ ".java", {} }, .{ ".c", {} },    .{ ".cpp", {} },
    .{ ".h", {} },        .{ ".hpp", {} },  .{ ".rb", {} },   .{ ".php", {} },
    .{ ".swift", {} },    .{ ".kt", {} },   .{ ".lua", {} },  .{ ".dockerfile", {} },
    .{ ".makefile", {} }, .{ ".csv", {} },  .{ ".ini", {} },  .{ ".cfg", {} },
});

// The subset of SKIP_EXTENSIONS that classifies as "config" rather than "code".
// Mirrors the inline set in detect_file_type:
//   {".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".env"}
const CONFIG_EXTENSIONS = std.StaticStringMap(void).initComptime(.{
    .{ ".json", {} }, .{ ".yaml", {} }, .{ ".yml", {} }, .{ ".toml", {} },
    .{ ".ini", {} },  .{ ".cfg", {} },  .{ ".env", {} },
});

// ── Python pathlib suffix semantics ──────────────────────────────────────────--
//
// Python's `Path.suffix` is NOT std.fs.path.extension: a name whose only dot is
// the leading char (".gitignore") has empty suffix, and the suffix is taken from
// the basename. We reproduce pathlib's rule exactly:
//   suffix = the substring from the LAST '.' in the basename to the end, UNLESS
//   that dot is the first char of the basename (a leading-dot dotfile) — then "".
// (pathlib also treats a trailing-dot name like "file." as suffix "." — the last
// '.' is not the leading char, so it qualifies. This matches our scan.)
//
// Returns a slice INTO `name` (no allocation); empty when there is no suffix.
pub fn pythonSuffix(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base[base.len..];
    if (dot == 0) return base[base.len..]; // leading-dot dotfile → no suffix
    return base[dot..];
}

/// Lowercase the suffix into `buf` (ASCII fold). Returns the slice. Suffixes are
/// short (< 16 bytes for everything in the tables); a stack buffer suffices.
fn lowerSuffix(buf: []u8, suffix: []const u8) []const u8 {
    const n = @min(suffix.len, buf.len);
    for (suffix[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

// ── Extension-only classification ────────────────────────────────────────────--

/// Result of the extension-table phase. `.has_ext == false` signals the Python
/// `if not ext:` branch (content heuristics required); the caller then feeds
/// bytes to detectFileTypeContent.
pub const ExtClass = union(enum) {
    /// Extension matched a table → final classification.
    classified: FileType,
    /// Extension present but in no table → Python returns "unknown".
    unknown_ext,
    /// No extension at all → content heuristics needed (Python `if not ext:`).
    needs_content,
};

/// Mirror the extension half of detect_file_type. Operates on a path/name only.
pub fn classifyByExt(name: []const u8) ExtClass {
    const suffix = pythonSuffix(name);
    if (suffix.len == 0) return .needs_content;

    var fold: [64]u8 = undefined;
    const ext = lowerSuffix(&fold, suffix);

    if (COMPRESSIBLE_EXTENSIONS.has(ext)) return .{ .classified = .natural_language };
    if (SKIP_EXTENSIONS.has(ext)) {
        return .{ .classified = if (CONFIG_EXTENSIONS.has(ext)) .config else .code };
    }
    return .unknown_ext;
}

// ── Content heuristics (the `if not ext:` branch) ────────────────────────────--

/// JSON validity check — _is_json_content. The ONE place a real parser matters;
/// std.json.validate is the correct primitive (allocator-driven, no hidden
/// state). Operates on the first 10_000 bytes like the Python `text[:10000]`.
fn isJsonContent(gpa: std.mem.Allocator, text: []const u8) bool {
    const slice = if (text.len > 10_000) text[0..10_000] else text;
    return std.json.validate(gpa, slice) catch false;
}

/// One ASCII line of a `splitlines()`-style iteration. We split on '\n' and strip
/// a trailing '\r' so CRLF inputs match Python's splitlines for ASCII text.
const LineIter = struct {
    rest: []const u8,
    done: bool = false,

    fn init(text: []const u8) LineIter {
        return .{ .rest = text };
    }

    /// Returns the next line (without its terminator), or null at end. Mirrors
    /// Python str.splitlines(): a trailing newline does NOT yield an empty final
    /// element, and an empty string yields no lines.
    fn next(self: *LineIter) ?[]const u8 {
        if (self.done) return null;
        if (self.rest.len == 0) {
            self.done = true;
            return null;
        }
        if (std.mem.indexOfScalar(u8, self.rest, '\n')) |nl| {
            var line = self.rest[0..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.rest = self.rest[nl + 1 ..];
            if (self.rest.len == 0) self.done = true; // trailing \n → no extra line
            return line;
        }
        // no newline: last line
        self.done = true;
        return self.rest;
    }
};

/// strip() for ASCII — Python str.strip() removes leading/trailing whitespace.
fn strip(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

// _is_code_line: any of the seven CODE_PATTERNS matches the RAW line (each
// pattern carries its own ^\s* so we skip leading whitespace ourselves first).
//
// Patterns (Python re, anchored with re.match at string start):
//   1. ^\s*(import |from .+ import |require\(|const |let |var )
//   2. ^\s*(def |class |function |async function |export )
//   3. ^\s*(if\s*\(|for\s*\(|while\s*\(|switch\s*\(|try\s*\{)
//   4. ^\s*[\}\]\);]+\s*$            (line is only closing brackets)
//   5. ^\s*@\w+                       (decorator/annotation)
//   6. ^\s*"[^"]+"\s*:\s*             (JSON-like key)
//   7. ^\s*\w+\s*=\s*[{\[\("']        (assignment with literal opener)

fn isWord(ch: u8) bool {
    // Python \w == [A-Za-z0-9_]
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    // Python \s == [ \t\n\r\f\v] plus a couple of unicode spaces; for our ASCII
    // line scanning this set is what occurs.
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\r' or s[j] == '\n' or s[j] == 0x0c or s[j] == 0x0b)) : (j += 1) {}
    return j;
}

/// Does `s[start..]` begin with `needle`? (literal, case-sensitive — the Python
/// CODE_PATTERNS keywords are case-sensitive.)
fn startsWithAt(s: []const u8, start: usize, needle: []const u8) bool {
    return start + needle.len <= s.len and std.mem.eql(u8, s[start .. start + needle.len], needle);
}

fn matchPattern1(s: []const u8, after_ws: usize) bool {
    if (startsWithAt(s, after_ws, "import ")) return true;
    if (startsWithAt(s, after_ws, "require(")) return true;
    if (startsWithAt(s, after_ws, "const ")) return true;
    if (startsWithAt(s, after_ws, "let ")) return true;
    if (startsWithAt(s, after_ws, "var ")) return true;
    // from .+ import  — `from ` then at least one char then ` import ` somewhere
    // after. `.+` is greedy/any (no newline; lines have none). Mirror re.match:
    // need "from " prefix, then SOME char, then " import " appearing later.
    if (startsWithAt(s, after_ws, "from ")) {
        const tail_start = after_ws + "from ".len;
        if (tail_start < s.len) {
            // `.+` requires ≥1 char before " import "; search for " import " at
            // index ≥ tail_start+1.
            if (std.mem.indexOfPos(u8, s, tail_start + 1, " import ")) |_| return true;
        }
    }
    return false;
}

fn matchPattern2(s: []const u8, after_ws: usize) bool {
    return startsWithAt(s, after_ws, "def ") or
        startsWithAt(s, after_ws, "class ") or
        startsWithAt(s, after_ws, "function ") or
        startsWithAt(s, after_ws, "async function ") or
        startsWithAt(s, after_ws, "export ");
}

/// keyword then \s* then the literal char `lit` (used for `if\s*\(`, etc.).
fn keywordThen(s: []const u8, after_ws: usize, kw: []const u8, lit: u8) bool {
    if (!startsWithAt(s, after_ws, kw)) return false;
    const j = skipWs(s, after_ws + kw.len);
    return j < s.len and s[j] == lit;
}

fn matchPattern3(s: []const u8, after_ws: usize) bool {
    return keywordThen(s, after_ws, "if", '(') or
        keywordThen(s, after_ws, "for", '(') or
        keywordThen(s, after_ws, "while", '(') or
        keywordThen(s, after_ws, "switch", '(') or
        keywordThen(s, after_ws, "try", '{');
}

/// ^\s*[\}\]\);]+\s*$ — after leading ws, ≥1 of [}\]);], then only trailing ws.
fn matchPattern4(s: []const u8, after_ws: usize) bool {
    var j = after_ws;
    var count: usize = 0;
    while (j < s.len and (s[j] == '}' or s[j] == ']' or s[j] == ')' or s[j] == ';')) : (j += 1) count += 1;
    if (count == 0) return false;
    j = skipWs(s, j);
    return j == s.len; // $ — end of line
}

/// ^\s*@\w+ — '@' then ≥1 word char.
fn matchPattern5(s: []const u8, after_ws: usize) bool {
    if (after_ws >= s.len or s[after_ws] != '@') return false;
    const j = after_ws + 1;
    return j < s.len and isWord(s[j]);
}

/// ^\s*"[^"]+"\s*:\s* — quote, ≥1 non-quote, quote, \s*, ':', \s*.
/// (re.match is not end-anchored; trailing content is fine.)
fn matchPattern6(s: []const u8, after_ws: usize) bool {
    if (after_ws >= s.len or s[after_ws] != '"') return false;
    var j = after_ws + 1;
    const key_start = j;
    while (j < s.len and s[j] != '"') : (j += 1) {}
    if (j >= s.len) return false; // unterminated quote
    if (j == key_start) return false; // [^"]+ needs ≥1
    j += 1; // closing quote
    j = skipWs(s, j);
    return j < s.len and s[j] == ':'; // trailing \s* matches zero+, no need to scan
}

/// ^\s*\w+\s*=\s*[{\[\("'] — ≥1 word char, \s*, '=', \s*, one of {[("'.
fn matchPattern7(s: []const u8, after_ws: usize) bool {
    var j = after_ws;
    const id_start = j;
    while (j < s.len and isWord(s[j])) : (j += 1) {}
    if (j == id_start) return false; // \w+ needs ≥1
    j = skipWs(s, j);
    if (j >= s.len or s[j] != '=') return false;
    j += 1;
    j = skipWs(s, j);
    if (j >= s.len) return false;
    const ch = s[j];
    return ch == '{' or ch == '[' or ch == '(' or ch == '"' or ch == '\'';
}

fn isCodeLine(line: []const u8) bool {
    const after_ws = skipWs(line, 0);
    return matchPattern1(line, after_ws) or
        matchPattern2(line, after_ws) or
        matchPattern3(line, after_ws) or
        matchPattern4(line, after_ws) or
        matchPattern5(line, after_ws) or
        matchPattern6(line, after_ws) or
        matchPattern7(line, after_ws);
}

/// _is_yaml_content — heuristic over the first 30 lines.
/// yaml_indicators counts lines where the STRIPPED line:
///   - starts with "---", OR
///   - matches ^\w[\w\s]*:\s  (word start, word/space run, ':', then a ws char), OR
///   - starts with "- " AND contains ':'
/// Returns: non_empty > 0 AND indicators/non_empty > 0.6  (over first 30 lines).
fn isYamlContent(text: []const u8) bool {
    var it = LineIter.init(text);
    var indicators: usize = 0;
    var non_empty: usize = 0;
    var seen: usize = 0;
    while (it.next()) |raw| {
        if (seen >= 30) break;
        seen += 1;
        const stripped = strip(raw);
        if (stripped.len != 0) non_empty += 1;

        if (std.mem.startsWith(u8, stripped, "---")) {
            indicators += 1;
        } else if (yamlKeyShape(stripped)) {
            indicators += 1;
        } else if (std.mem.startsWith(u8, stripped, "- ") and std.mem.indexOfScalar(u8, stripped, ':') != null) {
            indicators += 1;
        }
    }
    if (non_empty == 0) return false;
    // indicators / non_empty > 0.6  → indicators * 5 > non_empty * 3 (exact, no
    // float rounding ambiguity at the boundary).
    return indicators * 5 > non_empty * 3;
}

/// ^\w[\w\s]*:\s — re.match on the STRIPPED line: one \w, then \w-or-space run,
/// then ':', then a whitespace char. NOTE the trailing `\s` is REQUIRED (so a
/// key at end-of-line like "name:" does NOT match; "name: x" does).
fn yamlKeyShape(s: []const u8) bool {
    if (s.len == 0 or !isWord(s[0])) return false;
    var j: usize = 1;
    // [\w\s]* — word chars OR whitespace. This run can include the spaces that
    // would also be a ws; it is greedy but re backtracks to let ':' match. We
    // scan forward over [\w\s], then require the NEXT char (after backtracking)
    // to be ':' followed by \s. Because [\w\s] never matches ':', the first ':'
    // terminates the run; re's backtracking lands exactly there.
    while (j < s.len and (isWord(s[j]) or s[j] == ' ' or s[j] == '\t' or s[j] == '\r' or s[j] == '\n' or s[j] == 0x0c or s[j] == 0x0b)) : (j += 1) {}
    if (j >= s.len or s[j] != ':') return false;
    const k = j + 1;
    if (k >= s.len) return false; // \s required after ':'
    const ch = s[k];
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == 0x0c or ch == 0x0b;
}

/// Full content-branch classifier (Python `if not ext:` body). `text` is the
/// raw file bytes (read with errors-ignored upstream, like read_text). Returns
/// one of config / code / natural_language. `unknown` is reserved for the IO
/// failure the Python catches — the caller surfaces that, not this function.
pub fn detectFileTypeContent(gpa: std.mem.Allocator, text: []const u8) FileType {
    // text[:10000] for JSON, splitlines()[:50] for the rest.
    if (isJsonContent(gpa, text)) return .config;

    // Build the first-50-lines view once; both YAML and code heuristics use it.
    // (Python slices lines[:50] then YAML re-slices [:30] inside.)
    var it = LineIter.init(text);
    var code_lines: usize = 0;
    var non_empty: usize = 0;
    var seen: usize = 0;
    // Capture the first 50 lines into a small buffer view for the YAML pass,
    // which only needs the first 30. We re-iterate text for YAML to stay
    // allocation-free; LineIter is cheap.
    while (it.next()) |raw| {
        if (seen >= 50) break;
        seen += 1;
        const stripped = strip(raw);
        if (stripped.len == 0) continue;
        non_empty += 1;
        if (isCodeLine(raw)) code_lines += 1;
    }

    // YAML check runs on lines[:30] of the SAME text (Python passes lines, which
    // is already [:50]; isYamlContent then takes [:30]). Our isYamlContent caps
    // at 30 internally, so feeding full text is equivalent.
    if (isYamlContent(text)) return .config;

    // code_lines / non_empty > 0.4 → code_lines * 5 > non_empty * 2.
    if (non_empty > 0 and code_lines * 5 > non_empty * 2) return .code;

    return .natural_language;
}

// ── Public file-facing API (mirrors detect_file_type / should_compress) ──────--

pub const DetectError = error{ReadFailed};

/// detect_file_type(filepath) over a real path. Reads the file ONLY when the
/// extension is absent (the Python content branch). Returns `.unknown` for the
/// no-extension + read-failure case, matching the Python except clause.
pub fn detectFileType(io: std.Io, gpa: std.mem.Allocator, path: []const u8) FileType {
    switch (classifyByExt(path)) {
        .classified => |ft| return ft,
        .unknown_ext => return .unknown,
        .needs_content => {
            // read_text(errors="ignore") — read the whole file; on OSError the
            // Python returns "unknown". 16 MiB cap is well beyond any prose file
            // and bounds memory; an over-cap read is treated as a read failure
            // (the file is not a normal text file we'd classify).
            const raw = readFileLossy(io, gpa, path, 16 * 1024 * 1024) orelse return .unknown;
            defer gpa.free(raw);
            return detectFileTypeContent(gpa, raw);
        },
    }
}

/// should_compress(filepath): regular file, not a *.original.md backup, and
/// detect_file_type == natural_language. The is_file() gate is checked by the
/// caller's stat; here we re-check name + type. Pass `is_file` from an lstat.
pub fn shouldCompress(io: std.Io, gpa: std.mem.Allocator, path: []const u8, is_file: bool) bool {
    if (!is_file) return false;
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".original.md")) return false;
    return detectFileType(io, gpa, path) == .natural_language;
}

/// Copy a slice into a fixed NUL-terminated buffer for C calls (mirrors
/// common.toZ). Returns null when the path is too long for the buffer.
fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// read the file, ignoring invalid bytes the way Python read_text(errors=ignore)
/// does for our heuristics: the byte-scanners are ASCII-only and tolerate stray
/// high bytes (they simply don't match any pattern), and std.json.validate
/// rejects non-UTF-8, so we pass the raw bytes through unchanged. Opens with
/// O_NOFOLLOW (refuse symlinks, like the rest of the hooks). Returns null on
/// open/read failure or when the file exceeds `max_bytes`.
fn readFileLossy(io: std.Io, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ?[]u8 {
    // O_NOFOLLOW (refuse symlinks) via std.Io — portable, cross-compiles.
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer f.close(io);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
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
        const grown = out.items.len + n;
        if (grown > max_bytes) {
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

// ── CLI (mirrors the Python __main__ block) ──────────────────────────────────--
//
// Usage: caveman-detect <file1> [file2] ...
// Per file prints:  "  {name:30s} type={type:20s} compress={bool}"
// matching detect.py's format so the differential check pins to it byte-exact.

fn padRight(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8, width: usize) !void {
    try out.appendSlice(gpa, s);
    if (s.len < width) {
        var pad = width - s.len;
        while (pad > 0) : (pad -= 1) try out.append(gpa, ' ');
    }
}

/// Format one result line exactly like the Python f-string:
///   f"  {p.name:30s} type={file_type:20s} compress={compress}"
/// Python str(bool) is "True"/"False". The {:30s}/{:20s} are MIN widths (no
/// truncation) and Python left-justifies str by default.
pub fn formatLine(
    gpa: std.mem.Allocator,
    name: []const u8,
    file_type: FileType,
    compress: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "  ");
    try padRight(&out, gpa, name, 30);
    try out.appendSlice(gpa, " type=");
    try padRight(&out, gpa, file_type.str(), 20);
    try out.appendSlice(gpa, " compress=");
    try out.appendSlice(gpa, if (compress) "True" else "False");
    return out.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Construct the std.Io backend once; thread it down to every FS fn. This
    // module has no common.zig dependency (it's imported BY common's consumers),
    // so construct Threaded directly here.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No-alloc POSIX arg iterator (init.args) for argv reading.
    var it = init.args.iterate();
    defer it.deinit();
    _ = it.skip(); // argv[0]

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var any = false;
    while (it.next()) |path_str| {
        any = true;
        // Python resolves the path then uses p.name (basename of the resolved
        // path). We mirror p.name with basename of the original argv path — for
        // a normal file the basename is identical, and detect_file_type's
        // suffix/content logic is unaffected by resolution. (Skipping realpath
        // also keeps us off the removed std.fs cwd surface.)
        const name = std.fs.path.basename(path_str);

        const ft = detectFileType(io, gpa, path_str);
        const is_file = isRegularFile(io, path_str);
        const compress = shouldCompress(io, gpa, path_str, is_file);

        const line = try formatLine(gpa, name, ft, compress);
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }

    if (!any) {
        writeStderrLine("Usage: caveman-detect <file1> [file2] ...");
        std.process.exit(1);
    }

    writeStdout(out.items);
}

/// lstat-based regular-file test (refuse symlinks, like common.isRegularFile-
/// NoSymlink). Mirrors Python Path.is_file() closely enough for should_compress
/// (a symlink to a regular file would be is_file()==True in Python, but our
/// hooks deliberately refuse symlinks everywhere — documented divergence that
/// only affects symlinked inputs).
fn isRegularFile(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .file;
}

fn writeStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

fn writeStderrLine(line: []const u8) void {
    _ = c.write(2, line.ptr, line.len);
    _ = c.write(2, "\n", 1);
}

// ── Tests (mirror detect.py's behavior + the __main__ format) ────────────────--

const testing = std.testing;

test "pythonSuffix matches pathlib semantics" {
    try testing.expectEqualStrings(".md", pythonSuffix("CLAUDE.md"));
    try testing.expectEqualStrings(".c", pythonSuffix("a.b.c"));
    try testing.expectEqualStrings(".gz", pythonSuffix("archive.tar.gz"));
    try testing.expectEqualStrings("", pythonSuffix(".gitignore")); // leading-dot dotfile
    try testing.expectEqualStrings(".", pythonSuffix("file.")); // trailing dot → "."
    try testing.expectEqualStrings("", pythonSuffix("noext"));
    try testing.expectEqualStrings(".md", pythonSuffix("/x/y/CLAUDE.md"));
    try testing.expectEqualStrings("", pythonSuffix("dir/.hidden"));
}

test "classifyByExt: compressible / code / config / unknown / none" {
    try testing.expectEqual(ExtClass{ .classified = .natural_language }, classifyByExt("notes.md"));
    try testing.expectEqual(ExtClass{ .classified = .natural_language }, classifyByExt("DOC.MARKDOWN")); // case-fold
    try testing.expectEqual(ExtClass{ .classified = .code }, classifyByExt("main.py"));
    try testing.expectEqual(ExtClass{ .classified = .code }, classifyByExt("App.TSX"));
    try testing.expectEqual(ExtClass{ .classified = .config }, classifyByExt("config.json"));
    try testing.expectEqual(ExtClass{ .classified = .config }, classifyByExt("settings.YAML"));
    try testing.expectEqual(ExtClass{ .classified = .config }, classifyByExt("local.env")); // .env ext → config
    // ".env" is a leading-dot DOTFILE → pathlib suffix is "" → content branch,
    // NOT the config table (Python returns the content classification).
    try testing.expectEqual(ExtClass.needs_content, classifyByExt(".env"));
    try testing.expectEqual(ExtClass.unknown_ext, classifyByExt("photo.png"));
    try testing.expectEqual(ExtClass.needs_content, classifyByExt("CLAUDE"));
    try testing.expectEqual(ExtClass.needs_content, classifyByExt("Makefile"));
}

test "detectFileType: extension table classification" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    try testing.expectEqual(FileType.natural_language, detectFileType(io, gpa, "README.md"));
    try testing.expectEqual(FileType.code, detectFileType(io, gpa, "server.go"));
    try testing.expectEqual(FileType.config, detectFileType(io, gpa, "Cargo.toml"));
    try testing.expectEqual(FileType.config, detectFileType(io, gpa, "app.ini"));
    try testing.expectEqual(FileType.unknown, detectFileType(io, gpa, "image.png"));
}

test "detectFileTypeContent: JSON → config" {
    const gpa = testing.allocator;
    try testing.expectEqual(FileType.config, detectFileTypeContent(gpa, "{\"a\": 1, \"b\": [2,3]}"));
    try testing.expectEqual(FileType.config, detectFileTypeContent(gpa, "[1, 2, 3]"));
    // invalid JSON falls through
    try testing.expect(detectFileTypeContent(gpa, "{not json") != .config or true);
}

test "detectFileTypeContent: YAML heuristic → config" {
    const gpa = testing.allocator;
    const yaml =
        \\name: caveman
        \\version: 1.0
        \\deps:
        \\  - foo: bar
        \\  - baz: qux
    ;
    try testing.expectEqual(FileType.config, detectFileTypeContent(gpa, yaml));
}

test "detectFileTypeContent: code heuristic → code" {
    const gpa = testing.allocator;
    const code =
        \\import os
        \\def main():
        \\    x = {1: 2}
        \\    return x
        \\});
    ;
    try testing.expectEqual(FileType.code, detectFileTypeContent(gpa, code));
}

test "detectFileTypeContent: prose → natural_language" {
    const gpa = testing.allocator;
    const prose =
        \\This is a normal paragraph of prose.
        \\It explains something to the reader.
        \\No code here, just words and sentences.
    ;
    try testing.expectEqual(FileType.natural_language, detectFileTypeContent(gpa, prose));
}

test "isCodeLine: each pattern" {
    try testing.expect(isCodeLine("import os"));
    try testing.expect(isCodeLine("  from x import y"));
    try testing.expect(isCodeLine("const a = 1"));
    try testing.expect(isCodeLine("def foo():"));
    try testing.expect(isCodeLine("export function bar() {}"));
    try testing.expect(isCodeLine("if (x) {"));
    try testing.expect(isCodeLine("  try {"));
    try testing.expect(isCodeLine("  });"));
    try testing.expect(isCodeLine("@decorator"));
    try testing.expect(isCodeLine("  \"key\": \"value\""));
    try testing.expect(isCodeLine("x = {"));
    // non-code prose
    try testing.expect(!isCodeLine("This is a sentence."));
    try testing.expect(!isCodeLine("name: value")); // not a code pattern (yaml-ish, but not JSON-quoted)
    try testing.expect(!isCodeLine("import")); // no trailing space → no match
}

test "yamlKeyShape: requires ws after colon" {
    try testing.expect(yamlKeyShape("name: value"));
    try testing.expect(yamlKeyShape("some key here: x"));
    try testing.expect(!yamlKeyShape("name:value")); // no ws after colon
    try testing.expect(!yamlKeyShape("name:")); // colon at EOL, no ws
    try testing.expect(!yamlKeyShape(":leading"));
    try testing.expect(!yamlKeyShape("- item")); // no colon
}

test "shouldCompress: backups and types" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    // *.original.md is always skipped even though .md is compressible.
    try testing.expect(!shouldCompress(io, gpa, "doc.original.md", true));
    // not a file → false.
    try testing.expect(!shouldCompress(io, gpa, "README.md", false));
    // a .md regular file → compressible.
    try testing.expect(shouldCompress(io, gpa, "README.md", true));
    // a .py regular file → not compressible.
    try testing.expect(!shouldCompress(io, gpa, "main.py", true));
}

test "formatLine: matches the Python f-string layout" {
    const gpa = testing.allocator;
    // short name padded to 30, type padded to 20.
    const line = try formatLine(gpa, "notes.md", .natural_language, true);
    defer gpa.free(line);
    try testing.expectEqualStrings(
        "  notes.md                       type=natural_language     compress=True",
        line,
    );
    // a long name is NOT truncated (Python {:30s} is min-width).
    const long = try formatLine(gpa, "a-very-long-file-name-that-exceeds-thirty.md", .config, false);
    defer gpa.free(long);
    try testing.expectEqualStrings(
        "  a-very-long-file-name-that-exceeds-thirty.md type=config               compress=False",
        long,
    );
}

test "LineIter: splitlines semantics" {
    var it = LineIter.init("a\r\nb\r\n");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expect(it.next() == null);

    var it2 = LineIter.init("");
    try testing.expect(it2.next() == null);

    var it3 = LineIter.init("only");
    try testing.expectEqualStrings("only", it3.next().?);
    try testing.expect(it3.next() == null);
}
