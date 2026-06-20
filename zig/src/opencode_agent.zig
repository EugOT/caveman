//! caveman → opencode subagent frontmatter sanitizer — Zig 0.16 port of
//! bin/lib/opencode-agent.js (issue #386).
//!
//! Strips the `tools:` field from a Claude-Code-style subagent frontmatter so
//! the file is valid for opencode, whose schema rejects the YAML array form
//! (`tools: [Read, Grep, Bash]`):
//!
//!   Configuration is invalid at .../agents/cavecrew-reviewer.md
//!   ↳ Expected object | undefined, got ["Read","Grep","Bash"] tools
//!
//! opencode allows `tools` to be a map (`{read: true}`) or omitted entirely.
//! Omitting falls back to opencode's default tool set, which is what the
//! cavecrew subagent prompts already self-restrict against in their body, so
//! dropping the array form is safe.
//!
//! This is a pure string transform — no syscalls, allocator-only. Imported by
//! the installer port (R4b stage 2) to sanitize agents/cavecrew-*.md on copy.
//! Byte-exact with the JS: same fence (`---\n`), same first `\n---` end probe,
//! same `^tools[ \t]*:` field match, same `^[ \t]` continuation drop, same
//! `out.join('\n')` reconstruction.

const std = @import("std");

const FRONTMATTER_FENCE = "---\n";

/// JS: `/^tools[ \t]*:/` — line begins with `tools` then optional spaces/tabs
/// then a colon.
fn isToolsField(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "tools")) return false;
    var i: usize = "tools".len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == ':';
}

/// JS: `/^[ \t]/` — line begins with a space or tab (a YAML continuation /
/// nested-list line under the dropped key).
fn isContinuation(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

/// Strip the `tools:` frontmatter field (inline array OR multi-line list form)
/// from `content`, returning a freshly-allocated buffer the caller owns.
///
/// Mirrors stripOpencodeAgentTools exactly:
///   - no leading `---\n` fence → return a copy of the input unchanged
///   - no closing `\n---` after the fence → return a copy unchanged
///   - otherwise split frontmatter at the first `\n---` (inclusive of the
///     leading newline in `rest`), drop the `tools:` line + its indented
///     continuation lines, rejoin with `\n`, and re-fence.
///
/// The JS `non-string input returns unchanged` branch has no Zig analogue —
/// the type system guarantees `content` is a `[]const u8`. Callers that have an
/// optional should guard before calling.
pub fn stripOpencodeAgentTools(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, content, FRONTMATTER_FENCE)) {
        return gpa.dupe(u8, content);
    }
    // JS: content.indexOf('\n---', FRONTMATTER_FENCE.length)
    const search_from = FRONTMATTER_FENCE.len;
    const fm_end_rel = std.mem.indexOf(u8, content[search_from..], "\n---") orelse
        return gpa.dupe(u8, content);
    const fm_end = search_from + fm_end_rel;

    const fm = content[FRONTMATTER_FENCE.len..fm_end];
    const rest = content[fm_end..]; // begins with "\n---..."

    // Walk fm line-by-line (split on '\n'), dropping the tools field block.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, FRONTMATTER_FENCE);

    var dropping = false;
    var first = true;
    var it = std.mem.splitScalar(u8, fm, '\n');
    while (it.next()) |line| {
        if (dropping) {
            if (isContinuation(line)) continue;
            dropping = false;
        }
        if (isToolsField(line)) {
            dropping = true;
            continue;
        }
        // JS reconstruction is out.join('\n'): a newline BEFORE every kept line
        // except the first.
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, line);
    }

    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn frontmatterOf(content: []const u8) []const u8 {
    // Extract between the first "---\n" and the next "\n---".
    const fence = "---\n";
    std.debug.assert(std.mem.startsWith(u8, content, fence));
    const after = content[fence.len..];
    const end = std.mem.indexOf(u8, after, "\n---").?;
    return after[0..end];
}

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

test "strips inline tools array from frontmatter" {
    const gpa = testing.allocator;
    const src =
        "---\nname: test-agent\ndescription: short description\ntools: [Read, Grep, Bash]\nmodel: haiku\n---\nbody line one\nbody line two\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    const fm = frontmatterOf(out);
    try testing.expect(std.mem.indexOf(u8, fm, "tools") == null);
    try testing.expect(containsLine(fm, "name: test-agent"));
    try testing.expect(containsLine(fm, "description: short description"));
    try testing.expect(containsLine(fm, "model: haiku"));
    try testing.expect(std.mem.indexOf(u8, out, "body line one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "body line two") != null);
}

test "strips multi-line tools list with indented continuation" {
    const gpa = testing.allocator;
    const src =
        "---\nname: test-agent\ntools:\n  - Read\n  - Grep\n  - Bash\nmodel: haiku\n---\nbody\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    const fm = frontmatterOf(out);
    try testing.expect(std.mem.indexOf(u8, fm, "tools") == null);
    try testing.expect(std.mem.indexOf(u8, fm, "- Read") == null);
    try testing.expect(containsLine(fm, "name: test-agent"));
    try testing.expect(containsLine(fm, "model: haiku"));
}

test "preserves folded description block when tools follows" {
    const gpa = testing.allocator;
    const src =
        "---\nname: cavecrew-reviewer\ndescription: >\n  Diff/branch/file reviewer. One line per finding, severity-tagged, no praise,\n  no scope creep. Output format `path:line: <emoji> <severity>: <problem>. <fix>.`\ntools: [Read, Grep, Bash]\nmodel: haiku\n---\nbody\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    const fm = frontmatterOf(out);
    try testing.expect(std.mem.indexOf(u8, fm, "\ntools:") == null);
    try testing.expect(!isToolsField(fm[0..@min(fm.len, 6)]) or std.mem.indexOf(u8, fm, "tools:") == null);
    try testing.expect(containsLine(fm, "description: >"));
    try testing.expect(std.mem.indexOf(u8, fm, "Diff/branch/file reviewer") != null);
    try testing.expect(std.mem.indexOf(u8, fm, "no scope creep") != null);
    try testing.expect(containsLine(fm, "model: haiku"));
}

test "returns input unchanged when no frontmatter fence" {
    const gpa = testing.allocator;
    const src = "just body, no frontmatter\ntools: [Read]\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings(src, out);
}

test "returns input unchanged when frontmatter has no tools field" {
    const gpa = testing.allocator;
    const src = "---\nname: x\nmodel: haiku\n---\nbody\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    try testing.expectEqualStrings(src, out);
}

test "body is byte-identical after transform" {
    const gpa = testing.allocator;
    const src = "---\nname: a\ntools: [Read]\n---\nbody one\nbody two\n";
    const out = try stripOpencodeAgentTools(gpa, src);
    defer gpa.free(out);
    // Body = everything from the first "\n---" onward.
    const body_in = src[std.mem.indexOf(u8, src[4..], "\n---").? + 4 ..];
    const body_out = out[std.mem.indexOf(u8, out[4..], "\n---").? + 4 ..];
    try testing.expectEqualStrings(body_in, body_out);
}
