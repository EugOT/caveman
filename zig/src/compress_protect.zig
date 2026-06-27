//! caveman-compress structural guards — Zig 0.16 port of the three pure-logic
//! helpers in skills/caveman-compress/scripts/compress.py:
//!
//!   - splitFrontmatter   ← split_frontmatter   (FRONTMATTER_REGEX)
//!   - isSensitivePath    ← is_sensitive_path   (SENSITIVE_BASENAME_REGEX +
//!                          SENSITIVE_PATH_COMPONENTS + SENSITIVE_NAME_TOKENS)
//!   - stripLlmWrapper    ← strip_llm_wrapper   (OUTER_FENCE_REGEX)
//!
//! Pure string/path logic only — NO LLM call, NO subprocess, NO filesystem
//! access. Everything that allocates takes an explicit std.mem.Allocator. The
//! Python relies on `re` (PCRE-ish) and pathlib; Zig std ships neither a regex
//! engine nor pathlib, so each pattern is reproduced as a targeted byte scanner
//! with byte-exact semantics validated against the Python via the differential
//! check in the R5 task (run the reference harness, byte-compare both outputs).
//!
//! Where Zig std already does the job we use it (std.mem.startsWith/indexOf/
//! indexOfPos/tokenizeScalar, std.ascii.toLower/eqlIgnoreCase). The regex
//! scanners are hand-rolled ONLY because std has no regex — they are the
//! natural, minimal solution for the fixed patterns here, not a reinvention of
//! something std provides.

const std = @import("std");

// ── splitFrontmatter ─────────────────────────────────────────────────────────

/// Result of splitFrontmatter: views into the ORIGINAL `text` (no allocation).
/// `frontmatter` is the full `---\r?\n … \r?\n---\r?\n` block (delimiters and
/// trailing newline included) or empty; `body` is the remainder. When no
/// frontmatter is present, frontmatter == "" and body == text (the whole input),
/// matching the Python `return "", text`.
pub const Frontmatter = struct {
    frontmatter: []const u8,
    body: []const u8,
};

/// Mirror Python FRONTMATTER_REGEX = r"\A(---\r?\n.*?\r?\n---\r?\n)(.*)" + DOTALL:
///
///   - `\A`         → must start at byte 0.
///   - `---\r?\n`   → literal `---`, optional CR, mandatory LF (the opening fence).
///   - `.*?`        → minimal any-bytes (DOTALL ⇒ newlines included).
///   - `\r?\n---\r?\n` → optional CR, LF, literal `---`, optional CR, LF (closing).
///   - `(.*)`       → the body (DOTALL ⇒ to end of string).
///
/// The non-greedy `.*?` means the FIRST closing fence wins. Because the opening
/// fence already consumes its own trailing LF, the closing-fence match needs a
/// SEPARATE preceding `\r?\n` — so an input like `---\n---\nbody` does NOT match
/// (no newline between the two fences), exactly as Python reports.
///
/// Returns views into `text`; never allocates, never fails.
pub fn splitFrontmatter(text: []const u8) Frontmatter {
    // Opening fence: "---" then optional '\r' then '\n'.
    if (!std.mem.startsWith(u8, text, "---")) return .{ .frontmatter = "", .body = text };
    var open_end: usize = 3;
    if (open_end < text.len and text[open_end] == '\r') open_end += 1;
    if (open_end >= text.len or text[open_end] != '\n') return .{ .frontmatter = "", .body = text };
    open_end += 1; // past the opening fence's LF

    // Scan forward for the FIRST closing fence: "\r?\n---\r?\n" (non-greedy .*?).
    // Search for "\n---" starting from open_end; for each hit, verify the byte
    // before the '\n' may be '\r' (consumed as part of the optional \r) and that
    // what follows "---" is an optional '\r' then a mandatory '\n'.
    var search: usize = open_end;
    while (std.mem.indexOfPos(u8, text, search, "\n---")) |nl| {
        // nl points at the '\n'. The closing fence proper starts at the '\n'
        // (the optional '\r' belongs to the regex's `\r?` BEFORE `\n`, i.e. it
        // is part of the .*? — Python treats `\r?\n` as the boundary, where the
        // '\r' is optional and matched greedily by the .*? backtracking. In
        // practice a CRLF file has the '\r' immediately before this '\n', and it
        // is captured inside group 1 because the regex's `\r?\n` matches it.)
        var after = nl + 4; // past "\n---"
        if (after < text.len and text[after] == '\r') after += 1;
        if (after < text.len and text[after] == '\n') {
            after += 1; // past closing fence's trailing LF
            return .{ .frontmatter = text[0..after], .body = text[after..] };
        }
        // Not a valid closing fence here; keep scanning past this '\n'.
        search = nl + 1;
    }
    return .{ .frontmatter = "", .body = text };
}

// ── isSensitivePath ──────────────────────────────────────────────────────────

const SENSITIVE_PATH_COMPONENTS = [_][]const u8{
    ".ssh", ".aws", ".gnupg", ".kube", ".docker",
};

const SENSITIVE_NAME_TOKENS = [_][]const u8{
    "secret", "credential", "password", "passwd",
    "apikey", "accesskey",  "token",    "privatekey",
};

/// Sensitive-file extensions (the `.*\.(…)$` arm of SENSITIVE_BASENAME_REGEX).
/// Matched case-insensitively against the basename's final `.`-suffix.
const SENSITIVE_EXTENSIONS = [_][]const u8{
    "pem", "key", "p12", "pfx", "crt", "cer", "jks", "keystore", "asc", "gpg",
};

/// Heuristic denylist for files that must never be shipped to a third-party API.
/// Byte-exact port of is_sensitive_path:
///   1. basename matches SENSITIVE_BASENAME_REGEX (case-insensitive), OR
///   2. any path component (lowercased) is in SENSITIVE_PATH_COMPONENTS, OR
///   3. the basename with `[_\-\s.]` stripped + lowercased contains any token.
///
/// Path splitting mirrors pathlib.PurePosixPath on POSIX: tokens are `/`-
/// separated, with empty and `.` segments dropped (`..` is kept but never
/// matches the component set). The basename is the last such segment. Pure;
/// never allocates, never fails.
pub fn isSensitivePath(filepath: []const u8) bool {
    const name = posixBasename(filepath);

    if (sensitiveBasenameMatch(name)) return true;

    // Any path component (lowercased) in the sensitive set.
    var it = std.mem.tokenizeScalar(u8, filepath, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue; // pathlib drops '.' segments
        for (SENSITIVE_PATH_COMPONENTS) |comp| {
            if (std.ascii.eqlIgnoreCase(seg, comp)) return true;
        }
    }

    // Normalize separators: strip every '_', '-', whitespace, '.', lowercase,
    // then substring-match the token list (re.sub(r"[_\-\s.]", "", name.lower())).
    return normalizedNameHasToken(name);
}

/// pathlib.PurePosixPath(filepath).name — the last `/`-separated segment that is
/// neither empty nor `.`. Returns a view into `filepath`; "" when none.
fn posixBasename(filepath: []const u8) []const u8 {
    var name: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, filepath, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        name = seg;
    }
    return name;
}

/// SENSITIVE_BASENAME_REGEX, anchored `^(…)$`, case-insensitive. Each alternative
/// is a fixed shape, so we test them directly instead of running a regex engine.
fn sensitiveBasenameMatch(name: []const u8) bool {
    if (name.len == 0) return false;

    // .env(\..+)?  → ".env" optionally followed by '.' + at least one char.
    if (dotPrefixArm(name, ".env")) return true;
    // .netrc  (exact)
    if (std.ascii.eqlIgnoreCase(name, ".netrc")) return true;
    // credentials(\..+)?
    if (dotPrefixArm(name, "credentials")) return true;
    // secrets?(\..+)?  → "secret" or "secrets", optional ".<+>"
    if (dotPrefixArm(name, "secret")) return true;
    if (dotPrefixArm(name, "secrets")) return true;
    // passwords?(\..+)?
    if (dotPrefixArm(name, "password")) return true;
    if (dotPrefixArm(name, "passwords")) return true;
    // id_(rsa|dsa|ecdsa|ed25519)(\.pub)?
    if (idKeyArm(name)) return true;
    // authorized_keys / known_hosts (exact)
    if (std.ascii.eqlIgnoreCase(name, "authorized_keys")) return true;
    if (std.ascii.eqlIgnoreCase(name, "known_hosts")) return true;
    // .*\.(pem|key|…|gpg)  → basename ends with ".<ext>" (case-insensitive),
    // where the `.*` swallows everything up to the final matching extension.
    if (extensionArm(name)) return true;

    return false;
}

/// Match `^base(\..+)?$` case-insensitively: exactly `base`, or `base` + '.' +
/// at least one more byte.
fn dotPrefixArm(name: []const u8, base: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, base)) return true;
    if (name.len > base.len + 1 and
        std.ascii.eqlIgnoreCase(name[0..base.len], base) and
        name[base.len] == '.')
    {
        return true; // ".<+>" — `\..+` requires >= 1 byte after the dot.
    }
    return false;
}

/// Match `^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$` case-insensitively.
fn idKeyArm(name: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(name, "id_")) return false;
    var rest = name[3..];
    const algos = [_][]const u8{ "rsa", "dsa", "ecdsa", "ed25519" };
    for (algos) |algo| {
        if (rest.len >= algo.len and std.ascii.eqlIgnoreCase(rest[0..algo.len], algo)) {
            const tail = rest[algo.len..];
            if (tail.len == 0) return true;
            if (std.ascii.eqlIgnoreCase(tail, ".pub")) return true;
        }
    }
    return false;
}

/// Match `^.*\.(<ext>)$` case-insensitively. The regex `.*` is greedy, so the
/// match is the basename's FINAL `.`-delimited suffix: find the last '.', and
/// check the suffix after it against the extension list. A name with no '.' or
/// with the '.' at position 0 producing an empty/known suffix is handled by the
/// generic last-dot probe; `.*` consumes the rest regardless.
fn extensionArm(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    if (ext.len == 0) return false;
    for (SENSITIVE_EXTENSIONS) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// re.sub(r"[_\-\s.]", "", name.lower()) then substring-test each token.
/// `\s` here is the ASCII whitespace set re uses ([ \t\n\r\f\v]); paths never
/// contain newlines as a single component but we strip the full set to match.
fn normalizedNameHasToken(name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var n: usize = 0;
    for (name) |ch| {
        if (ch == '_' or ch == '-' or ch == '.' or isReWhitespace(ch)) continue;
        if (n >= buf.len) return false; // pathological length → no token (safe)
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const normalized = buf[0..n];
    for (SENSITIVE_NAME_TOKENS) |tok| {
        if (std.mem.indexOf(u8, normalized, tok) != null) return true;
    }
    return false;
}

fn isReWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c or ch == 0x0b;
}

// ── stripLlmWrapper ──────────────────────────────────────────────────────────

/// Strip an outer ```…``` / ~~~…~~~ fence wrapping the ENTIRE text. Byte-exact
/// port of OUTER_FENCE_REGEX = r"\A\s*(`{3,}|~{3,})[^\n]*\n(.*)\n\1\s*\Z" + DOTALL:
///
///   - `\A\s*`        → leading ASCII whitespace (incl. newlines) is skipped.
///   - `(`{3,}|~{3,})`→ an opening fence: 3+ of a single fence char. GREEDY, so
///                      the longest run is tried first, then backtracked shorter
///                      (but never below 3). The chosen length is captured as \1.
///   - `[^\n]*\n`     → the rest of the opening line (info string) + its newline.
///   - `(.*)`         → the body. GREEDY + DOTALL ⇒ extends as far as possible,
///                      so the LAST valid closing fence wins.
///   - `\n\1\s*\Z`    → a newline, the EXACT captured fence string, then only
///                      whitespace to end of string.
///
/// Returns a view into `text` (group 2) on a full-wrap match, otherwise `text`
/// unchanged. Pure; never allocates, never fails.
///
/// The fence length is NOT fixed: the engine picks the largest opener length
/// n ≥ 3 for which a closing line of exactly n identical fence chars (followed
/// only by whitespace to EOF) exists; among those, the body greedily reaches the
/// LAST such closer. We replicate that with an explicit length-backtrack loop.
pub fn stripLlmWrapper(text: []const u8) []const u8 {
    // \A\s* — skip leading whitespace.
    var p: usize = 0;
    while (p < text.len and isReWhitespace(text[p])) : (p += 1) {}
    if (p >= text.len) return text;

    const fence_ch = text[p];
    if (fence_ch != '`' and fence_ch != '~') return text;

    // Maximal opening run length at p.
    var max_run: usize = 0;
    while (p + max_run < text.len and text[p + max_run] == fence_ch) : (max_run += 1) {}
    if (max_run < 3) return text;

    // Greedy opener: try n from max_run down to 3.
    var n = max_run;
    while (n >= 3) : (n -= 1) {
        // Opening line: fence (n chars) + [^\n]* + '\n'. The remaining
        // (max_run - n) fence chars and anything else up to the first '\n' are
        // the info string ([^\n]*). Require a newline to terminate line 1.
        const after_fence = p + n;
        const nl = std.mem.indexOfScalarPos(u8, text, after_fence, '\n') orelse {
            // No newline after this opener length — shorter openers share the
            // same line, so none can match either. Bail.
            return text;
        };
        const body_start = nl + 1;

        // Body is greedy: find the LAST closing fence "\n" + (n × fence_ch) such
        // that everything after it to EOF is whitespace. Scan from the end.
        if (findLastClosingFence(text, body_start, fence_ch, n)) |body_end| {
            return text[body_start..body_end];
        }
        // No valid closer for this opener length; backtrack to a shorter opener.
    }
    return text;
}

/// Find the LAST index `e` in `text[from..]` such that text[e] == '\n', the
/// `n` bytes after it are all `fence_ch`, and everything after that fence run to
/// EOF is ASCII whitespace. Returns `e` (the body end, i.e. index of the closing
/// '\n') or null. Mirrors the greedy `(.*)` backtracking to the last `\n\1\s*\Z`.
fn findLastClosingFence(text: []const u8, from: usize, fence_ch: u8, n: usize) ?usize {
    if (from > text.len) return null;
    var i: usize = text.len;
    while (i > from) {
        i -= 1;
        if (text[i] != '\n') continue;
        // Need n fence chars immediately after the newline.
        const fstart = i + 1;
        if (fstart + n > text.len) continue;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (text[fstart + k] != fence_ch) break;
        }
        if (k != n) continue;
        // Everything after the n-char fence run must be \s* to EOF. Critically,
        // the byte right after the run must NOT be another fence char, else the
        // closing line has > n fence chars and `\1\s*` fails on it.
        var t = fstart + n;
        var ok = true;
        while (t < text.len) : (t += 1) {
            if (!isReWhitespace(text[t])) {
                ok = false;
                break;
            }
        }
        if (ok) return i; // body = text[body_start .. i]
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────────
//
// Mirror the Python __main__ behavior: the source has no explicit test block,
// so these tests assert the documented contract of each helper plus the exact
// truth tables captured from the live Python `re`/pathlib (see the R5
// differential). The differential check (zig/scripts/diff_compress_protect.sh)
// re-validates byte-equality on a broader fixture corpus.

const testing = std.testing;

test "splitFrontmatter: LF frontmatter splits with delimiters" {
    const r = splitFrontmatter("---\nkey: val\n---\nbody here\n");
    try testing.expectEqualStrings("---\nkey: val\n---\n", r.frontmatter);
    try testing.expectEqualStrings("body here\n", r.body);
}

test "splitFrontmatter: CRLF frontmatter keeps the CRs in group 1" {
    const r = splitFrontmatter("---\r\nkey: val\r\n---\r\nbody\r\n");
    try testing.expectEqualStrings("---\r\nkey: val\r\n---\r\n", r.frontmatter);
    try testing.expectEqualStrings("body\r\n", r.body);
}

test "splitFrontmatter: no frontmatter passes through unchanged" {
    const r = splitFrontmatter("no frontmatter here");
    try testing.expectEqualStrings("", r.frontmatter);
    try testing.expectEqualStrings("no frontmatter here", r.body);
}

test "splitFrontmatter: adjacent fences with no body line do NOT match" {
    // Python: r"\A(---\r?\n.*?\r?\n---\r?\n)(.*)" → no match (no \n between fences).
    const r = splitFrontmatter("---\n---\nbody");
    try testing.expectEqualStrings("", r.frontmatter);
    try testing.expectEqualStrings("---\n---\nbody", r.body);
}

test "splitFrontmatter: non-greedy — first closing fence wins" {
    const r = splitFrontmatter("---\na\n---\nb\n---\nc");
    try testing.expectEqualStrings("---\na\n---\n", r.frontmatter);
    try testing.expectEqualStrings("b\n---\nc", r.body);
}

test "splitFrontmatter: closing fence without trailing newline does NOT match" {
    const r = splitFrontmatter("---\nkey\n---");
    try testing.expectEqualStrings("", r.frontmatter);
    try testing.expectEqualStrings("---\nkey\n---", r.body);
}

test "splitFrontmatter: opening fence with trailing space is not a fence" {
    const r = splitFrontmatter("--- \nnot real fence (space)\n");
    try testing.expectEqualStrings("", r.frontmatter);
    try testing.expectEqualStrings("--- \nnot real fence (space)\n", r.body);
}

test "isSensitivePath: basename regex arms" {
    try testing.expect(isSensitivePath(".env"));
    try testing.expect(isSensitivePath(".env.local"));
    try testing.expect(isSensitivePath(".env.production"));
    try testing.expect(isSensitivePath(".netrc"));
    try testing.expect(isSensitivePath("credentials"));
    try testing.expect(isSensitivePath("credentials.json"));
    try testing.expect(isSensitivePath("secret"));
    try testing.expect(isSensitivePath("secrets"));
    try testing.expect(isSensitivePath("secrets.txt"));
    try testing.expect(isSensitivePath("password"));
    try testing.expect(isSensitivePath("passwords.db"));
    try testing.expect(isSensitivePath("id_rsa"));
    try testing.expect(isSensitivePath("id_rsa.pub"));
    try testing.expect(isSensitivePath("id_ed25519"));
    try testing.expect(isSensitivePath("authorized_keys"));
    try testing.expect(isSensitivePath("known_hosts"));
    try testing.expect(isSensitivePath("mykey.pem"));
    try testing.expect(isSensitivePath("cert.crt"));
    try testing.expect(isSensitivePath("store.jks"));
    try testing.expect(isSensitivePath("thing.PEM")); // case-insensitive ext
    try testing.expect(isSensitivePath("file.gpg"));
    try testing.expect(isSensitivePath("a.b.c.key")); // .* swallows prefix dots
    try testing.expect(isSensitivePath("UPPER.KEY"));
}

test "isSensitivePath: path component arm" {
    try testing.expect(isSensitivePath("/home/u/.ssh/config"));
    try testing.expect(isSensitivePath("/home/u/.aws/credentials"));
    try testing.expect(isSensitivePath("/proj/.docker/config.json"));
    try testing.expect(isSensitivePath("/x/.kube/y"));
    try testing.expect(isSensitivePath("/a/b/.GnuPG/x")); // case-insensitive comp
}

test "isSensitivePath: normalized-name token arm" {
    try testing.expect(isSensitivePath("api-key.txt")); // apikey
    try testing.expect(isSensitivePath("my_secret_notes.md")); // secret
    try testing.expect(isSensitivePath("accessKey.json")); // accesskey
    try testing.expect(isSensitivePath("PrivateKey.pem")); // privatekey (+ ext)
    try testing.expect(isSensitivePath("token.txt")); // token
    try testing.expect(isSensitivePath("passwd")); // passwd
    try testing.expect(isSensitivePath("app.token.js")); // token after norm
    try testing.expect(isSensitivePath("subdir/.env")); // basename .env
}

test "isSensitivePath: NOT sensitive" {
    try testing.expect(!isSensitivePath("notes.md"));
    try testing.expect(!isSensitivePath("README.md"));
    try testing.expect(!isSensitivePath("ENV")); // .env requires the leading dot
    try testing.expect(!isSensitivePath("myenv"));
    try testing.expect(!isSensitivePath("plain.txt"));
    // anchored $ — authorized_keys.bak is not the exact name, and the normalized
    // token list has no "authorizedkeys" entry.
    try testing.expect(!isSensitivePath("authorized_keys.bak"));
}

test "stripLlmWrapper: ```markdown … ``` strips to body" {
    try testing.expectEqualStrings("hello world", stripLlmWrapper("```markdown\nhello world\n```"));
}

test "stripLlmWrapper: multi-line body" {
    try testing.expectEqualStrings("body\nmore", stripLlmWrapper("```\nbody\nmore\n```"));
}

test "stripLlmWrapper: tilde fences" {
    try testing.expectEqualStrings("body", stripLlmWrapper("~~~\nbody\n~~~"));
    try testing.expectEqualStrings("body", stripLlmWrapper("~~~~~\nbody\n~~~~~"));
}

test "stripLlmWrapper: leading + trailing whitespace tolerated" {
    try testing.expectEqualStrings("body", stripLlmWrapper("  ```md\nbody\n```  "));
    try testing.expectEqualStrings("body", stripLlmWrapper("```\nbody\n```\n"));
    try testing.expectEqualStrings("body", stripLlmWrapper("\n\n```\nbody\n```"));
}

test "stripLlmWrapper: no fence returns input unchanged" {
    try testing.expectEqualStrings("no fence here", stripLlmWrapper("no fence here"));
    try testing.expectEqualStrings("```\nunclosed body", stripLlmWrapper("```\nunclosed body"));
}

test "stripLlmWrapper: inner fences kept; LAST closer wins (greedy body)" {
    try testing.expectEqualStrings(
        "inner ``` stuff\nx",
        stripLlmWrapper("```markdown\ninner ``` stuff\nx\n```"),
    );
    try testing.expectEqualStrings(
        "line1\n```\nline2",
        stripLlmWrapper("```\nline1\n```\nline2\n```"),
    );
}

test "stripLlmWrapper: mismatched fence char does NOT strip" {
    try testing.expectEqualStrings("```\na\n~~~", stripLlmWrapper("```\na\n~~~"));
}

test "stripLlmWrapper: opener length backtracks to find a closer" {
    // Opener greedily grabs 4 backticks, but only a 3-backtick closer exists →
    // backtrack opener to 3 (4th backtick becomes part of the info string).
    try testing.expectEqualStrings("body", stripLlmWrapper("````\nbody\n```"));
    // Symmetric: 3 open, 4 close → 4th backtick on closing line breaks \1\s* →
    // no match (no shorter/longer opener helps).
    try testing.expectEqualStrings("```\nbody\n````", stripLlmWrapper("```\nbody\n````"));
}

test "stripLlmWrapper: closing line with trailing non-ws does not match" {
    try testing.expectEqualStrings("```\nbody\n```extra", stripLlmWrapper("```\nbody\n```extra"));
    try testing.expectEqualStrings("body", stripLlmWrapper("```\nbody\n```   \n  "));
}

test "stripLlmWrapper: empty body between fences" {
    try testing.expectEqualStrings("", stripLlmWrapper("```\n\n```"));
}

test "stripLlmWrapper: info string is discarded" {
    try testing.expectEqualStrings("body", stripLlmWrapper("```info string here\nbody\n```"));
    try testing.expectEqualStrings(
        "const x = 1\nconst y = 2",
        stripLlmWrapper("```js\nconst x = 1\nconst y = 2\n```"),
    );
}
