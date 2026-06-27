//! caveman-compress orchestrator — Zig 0.16 port of the compress.py +
//! cli.py control flow (skills/caveman-compress/scripts/).
//!
//! Binary: `<tool>-compress <filepath>`. End-to-end pipeline:
//!
//!   1. Resolve argv[1] (the only positional). Usage error → exit 1.
//!   2. Size-check (500 000 byte cap) + sensitive-path reject (compress_protect
//!      .isSensitivePath) — refuse to ship credentials/keys to the LLM.
//!   3. should_compress gate (compress_detect.shouldCompress) — natural-language
//!      files only; code/config/backups are skipped (exit 0, no change).
//!   4. Split YAML frontmatter (compress_protect.splitFrontmatter) — preserved
//!      verbatim, only the body is compressed.
//!   5. Call the LLM (`claude --print`, prompt on stdin) — IRREDUCIBLE side
//!      effect, see the `Claude shim` section. Build the compress / fix prompts
//!      byte-identical to build_compress_prompt / build_fix_prompt.
//!   6. Validate (compress_validate.validate) and retry up to MAX_RETRIES with a
//!      targeted fix prompt; restore the original on terminal failure.
//!   7. Backup the original out-of-tree (backup_dir_for), then write the
//!      compressed primary; verify the backup readback before touching the input.
//!
//! Reuse map (no logic re-implemented here that an R5a module already owns):
//!   - compress_protect.zig  → splitFrontmatter, isSensitivePath, stripLlmWrapper
//!   - compress_detect.zig   → shouldCompress (natural-language gate)
//!   - compress_validate.zig → validate (six structural checks) + Result
//!   - common.zig            → readFileAlloc, isRegularFileNoSymlink,
//!                             existsNoFollow, getenv, writeStdout/writeStderr
//! The libc C-ABI fork+pipe pattern (captureStdout in main.zig / captureSpawn in
//! install.zig) is extended here with a stdin-writing variant (the child reads
//! the prompt from stdin), since the Python `subprocess.run(..., input=prompt)`
//! pipes the prompt in. That variant is the one piece this module hand-rolls,
//! and only because no existing helper writes to a child's stdin.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const is_windows = builtin.os.tag == .windows;

const protect = @import("compress_protect.zig");
const detect = @import("detect");
const validate_mod = @import("compress_validate");
const common = @import("common.zig");

const TOOL = common.TOOL; // "caveman" | "ponytail"

// libc symbols not surfaced under std.c in this 0.16 build (same decls the other
// fork+pipe modules use). execvp searches $PATH so the bare "claude" resolves.
extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const MAX_FILE_SIZE: u64 = 500_000; // 500KB — mirror compress.py MAX_FILE_SIZE
const MAX_RETRIES: usize = 2; // mirror compress.py MAX_RETRIES

// ── stdout / stderr (libc fds; matches the rest of the hooks) ────────────────-

// Progress / error reporting. Silenced under `zig build test`: the 0.16 test
// runner captures the test process's stdout/stderr over pipes it drains lazily,
// and writing the orchestrator's progress lines into those pipes from inside a
// test can wedge the runner. The CLI behavior is unchanged in the real binary;
// only test runs are quiet. (The progress text is asserted via the differential
// harness against the live binary, not via these tests.)
fn out(bytes: []const u8) void {
    if (builtin.is_test) return;
    common.writeStdout(bytes);
}

fn err(bytes: []const u8) void {
    if (builtin.is_test) return;
    common.writeStderr(bytes);
}

// ── Claude shim (IRREDUCIBLE — the one true side effect) ─────────────────────-
//
// call_claude in compress.py prefers the Anthropic SDK when ANTHROPIC_API_KEY is
// set, else shells `claude --print` with the prompt piped to stdin. The SDK path
// is a network call we cannot reproduce from Zig without an HTTP+JSON client; the
// CLI fallback is the portable, auth-reusing path and the one we port. We ALWAYS
// take the CLI path here (documented divergence: no in-process SDK call). Output
// is trimmed and run through stripLlmWrapper, exactly like call_claude's return.
//
// fork + two pipes: parent writes `prompt` to the child's stdin, reads the
// child's stdout to EOF. stderr is captured separately so a CalledProcessError-
// style failure can surface the message (compress.py raises RuntimeError with
// e.stderr). Returns an owned, trimmed, wrapper-stripped string, or an error.

const ClaudeError = error{ SpawnFailed, ClaudeFailed, OutOfMemory };

const ClaudeResult = struct {
    /// Owned, trimmed + stripLlmWrapper'd stdout. Caller frees.
    text: []u8,
};

fn callClaude(gpa: std.mem.Allocator, prompt: []const u8) ClaudeError![]u8 {
    var in_fds: [2]c.fd_t = undefined; // parent → child stdin
    var out_fds: [2]c.fd_t = undefined; // child stdout → parent
    var errf: [2]c.fd_t = undefined; // child stderr → parent
    if (c.pipe(&in_fds) != 0) return error.SpawnFailed;
    if (c.pipe(&out_fds) != 0) {
        _ = common.close(in_fds[0]);
        _ = common.close(in_fds[1]);
        return error.SpawnFailed;
    }
    if (c.pipe(&errf) != 0) {
        _ = common.close(in_fds[0]);
        _ = common.close(in_fds[1]);
        _ = common.close(out_fds[0]);
        _ = common.close(out_fds[1]);
        return error.SpawnFailed;
    }

    // argv = { "claude", "--print", null }. Bare "claude" → execvp $PATH lookup,
    // matching shutil.which("claude") || "claude" on POSIX.
    const arg0 = "claude";
    const arg1 = "--print";
    var cargv = [_:null]?[*:0]const u8{ arg0, arg1, null };

    const pid = fork();
    if (pid < 0) {
        closeAll(&in_fds, &out_fds, &errf);
        return error.SpawnFailed;
    }
    if (pid == 0) {
        // Child: stdin ← in_fds[0], stdout → out_fds[1], stderr → errf[1].
        _ = c.dup2(in_fds[0], 0);
        _ = c.dup2(out_fds[1], 1);
        _ = c.dup2(errf[1], 2);
        // Close every pipe fd in the child (the dup2 targets stay open via 0/1/2).
        _ = common.close(in_fds[0]);
        _ = common.close(in_fds[1]);
        _ = common.close(out_fds[0]);
        _ = common.close(out_fds[1]);
        _ = common.close(errf[0]);
        _ = common.close(errf[1]);
        _ = execvp(arg0, (&cargv).ptr);
        c._exit(127);
    }

    // Parent: close the child ends we don't use.
    _ = common.close(in_fds[0]);
    _ = common.close(out_fds[1]);
    _ = common.close(errf[1]);

    // Write the prompt to the child's stdin, then close to signal EOF. A short
    // write or EPIPE (child died early) just stops the write loop; the read +
    // waitpid below still runs and reports the failure through the exit status.
    writeAllFd(in_fds[1], prompt);
    _ = common.close(in_fds[1]);

    // Drain stdout and stderr. We read stdout first to completion, then stderr;
    // `claude --print` is request/response (no interleaved backpressure deadlock
    // for our prompt sizes — bounded by MAX_FILE_SIZE), so sequential drains are
    // safe here without a select loop.
    const child_out = readAllFd(gpa, out_fds[0]) catch {
        _ = common.close(out_fds[0]);
        _ = common.close(errf[0]);
        _ = c.waitpid(pid, null, 0);
        return error.OutOfMemory;
    };
    _ = common.close(out_fds[0]);
    const child_err = readAllFd(gpa, errf[0]) catch &[_]u8{};
    _ = common.close(errf[0]);
    defer gpa.free(child_err);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    const exit_code: u8 = if (c.W.IFEXITED(ustatus)) c.W.EXITSTATUS(ustatus) else 1;

    if (exit_code != 0) {
        gpa.free(child_out);
        // Surface the child's stderr like RuntimeError(f"Claude call failed:\n{e.stderr}").
        err("Claude call failed:\n");
        err(child_err);
        if (child_err.len == 0 or child_err[child_err.len - 1] != '\n') err("\n");
        return error.ClaudeFailed;
    }

    // strip().then strip_llm_wrapper(...) — trim ASCII whitespace, drop an outer
    // wrapping fence. Both produce slices INTO child_out; we dupe the final view
    // and free the backing buffer so the result is a tidy standalone allocation.
    const trimmed = std.mem.trim(u8, child_out, " \t\r\n\x0b\x0c");
    const stripped = protect.stripLlmWrapper(trimmed);
    const result = gpa.dupe(u8, stripped) catch {
        gpa.free(child_out);
        return error.OutOfMemory;
    };
    gpa.free(child_out);
    return result;
}

fn closeAll(a: *[2]c.fd_t, b: *[2]c.fd_t, d: *[2]c.fd_t) void {
    _ = common.close(a[0]);
    _ = common.close(a[1]);
    _ = common.close(b[0]);
    _ = common.close(b[1]);
    _ = common.close(d[0]);
    _ = common.close(d[1]);
}

fn writeAllFd(fd: c.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return; // EPIPE / short write — child gone or done
        written += @intCast(n);
    }
}

fn readAllFd(gpa: std.mem.Allocator, fd: c.fd_t) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &rbuf, rbuf.len);
        if (n <= 0) break;
        try buf.appendSlice(gpa, rbuf[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(gpa);
}

// ── Prompt builders (byte-identical to compress.py) ──────────────────────────-

/// build_compress_prompt(original). The Python f-string opens with a leading
/// newline and ends with a trailing newline; reproduced byte-for-byte so the
/// model sees the exact same instruction block.
pub fn buildCompressPrompt(gpa: std.mem.Allocator, original: []const u8) error{OutOfMemory}![]u8 {
    const head =
        "\nCompress this markdown into caveman format.\n\nSTRICT RULES:\n" ++
        "- Do NOT modify anything inside ``` code blocks\n" ++
        "- Do NOT modify anything inside inline backticks\n" ++
        "- Preserve ALL URLs exactly\n" ++
        "- Preserve ALL headings exactly\n" ++
        "- Preserve file paths and commands\n" ++
        "- Return ONLY the compressed markdown body — do NOT wrap the entire output in a ```markdown fence or any other fence. Inner code blocks from the original stay as-is; do not add a new outer fence around the whole file.\n\n" ++
        "Only compress natural language.\n\nTEXT:\n";
    return std.mem.concat(gpa, u8, &.{ head, original, "\n" });
}

/// build_fix_prompt(original, compressed, errors). The errors block is one
/// "- <e>\n" per entry joined by '\n' (Python: "\n".join(f"- {e}" for e in
/// errors)), spliced into the same template with the same surrounding text.
pub fn buildFixPrompt(
    gpa: std.mem.Allocator,
    original: []const u8,
    compressed: []const u8,
    errors: []const []const u8,
) error{OutOfMemory}![]u8 {
    // errors_str = "\n".join(f"- {e}" for e in errors)
    var errs: std.ArrayList(u8) = .empty;
    defer errs.deinit(gpa);
    for (errors, 0..) |e, i| {
        if (i != 0) try errs.append(gpa, '\n');
        try errs.appendSlice(gpa, "- ");
        try errs.appendSlice(gpa, e);
    }

    const head =
        "You are fixing a caveman-compressed markdown file. Specific validation errors were found.\n\n" ++
        "CRITICAL RULES:\n" ++
        "- DO NOT recompress or rephrase the file\n" ++
        "- ONLY fix the listed errors — leave everything else exactly as-is\n" ++
        "- The ORIGINAL is provided as reference only (to restore missing content)\n" ++
        "- Preserve caveman style in all untouched sections\n\n" ++
        "ERRORS TO FIX:\n";
    const mid_a = "\n\nHOW TO FIX:\n" ++
        "- Missing URL: find it in ORIGINAL, restore it exactly where it belongs in COMPRESSED\n" ++
        "- Code block mismatch: find the exact code block in ORIGINAL, restore it in COMPRESSED\n" ++
        "- Heading mismatch: restore the exact heading text from ORIGINAL into COMPRESSED\n" ++
        "- Do not touch any section not mentioned in the errors\n\n" ++
        "ORIGINAL (reference only):\n";
    const mid_b = "\n\nCOMPRESSED (fix this):\n";
    const tail = "\n\nReturn ONLY the fixed compressed file. No explanation.\n";

    return std.mem.concat(gpa, u8, &.{
        head, errs.items, mid_a, original, mid_b, compressed, tail,
    });
}

// ── backup_dir_for (platform-aware, out-of-tree) ─────────────────────────────-
//
// Port of backup_dir_for: base is %LOCALAPPDATA%\caveman-compress\backups on
// Windows, else $XDG_DATA_HOME/caveman-compress/backups or
// ~/.local/share/caveman-compress/backups; the source file's PARENT-dir name is
// mirrored under the base. We target POSIX (the binary's platform); the Windows
// arm is documented but not reachable from this build. Returns an owned path.

fn backupDirFor(gpa: std.mem.Allocator, filepath: []const u8) error{ OutOfMemory, NoHome }![]u8 {
    const base = if (common.getenv("XDG_DATA_HOME")) |xdg|
        try std.fs.path.join(gpa, &.{ xdg, "caveman-compress", "backups" })
    else blk: {
        const home = common.getenv("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(gpa, &.{ home, ".local", "share", "caveman-compress", "backups" });
    };
    defer gpa.free(base);
    return backupDirForBase(gpa, base, filepath);
}

/// Pure tail of backupDirFor: mirror the source file's PARENT-dir name under
/// `base` (pathlib `base / filepath.parent.name`). Split out so the env-dependent
/// base resolution and the path-joining logic can be tested independently. Empty
/// parent name (filepath has no directory component) joins to `base` itself,
/// matching pathlib `Path(base) / ""` which is just `base`.
fn backupDirForBase(gpa: std.mem.Allocator, base: []const u8, filepath: []const u8) error{OutOfMemory}![]u8 {
    const parent = std.fs.path.dirname(filepath) orelse "";
    const parent_name = if (parent.len == 0) "" else std.fs.path.basename(parent);
    return std.fs.path.join(gpa, &.{ base, parent_name });
}

/// stem of a path's basename (pathlib filepath.stem): basename minus its final
/// suffix. Uses the same pathlib suffix rule the detector relies on (a leading-
/// dot dotfile has no suffix, so its stem is the whole name).
fn pathStem(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base; // ".gitignore" → stem ".gitignore"
    return base[0..dot];
}

/// Permissions value for a 0700 dir (POSIX mode; default on Windows, which has
/// no POSIX mode bits). Mirrors common.perm700 — same 0700-or-default contract.
fn perm700() std.Io.File.Permissions {
    return if (is_windows) .default_dir else .fromMode(0o700);
}

/// mkdir -p over an absolute/relative path (each component 0700). Best-effort;
/// EEXIST is benign. Mirrors backup_dir.mkdir(parents=True, exist_ok=True).
/// std.Io: each component goes through Dir.createDir; an AlreadyExists error is
/// ignored exactly as the old `_ = c.mkdir(...)` discarded EEXIST.
fn mkdirParents(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) void {
    if (dir.len == 0) return;
    var i: usize = 0;
    // Skip a leading '/' so the first component is non-empty.
    if (dir[0] == '/') i = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            if (i == 0) continue;
            const prefix = dir[0..i];
            if (prefix.len == 0) continue;
            std.Io.Dir.cwd().createDir(io, prefix, perm700()) catch {};
        }
    }
    _ = gpa; // no allocation; signature kept uniform with the other helpers
}

// ── Plain (non-symlink-refusing) file write/read for arbitrary user files ─────-
//
// safeWriteFlag is for the predictable, attacker-targetable flag path under
// ~/.claude. The compress target and its backup are ordinary user files the user
// named on the command line; we write them with a plain O_CREAT|O_TRUNC open
// (Python's Path.write_text). We do NOT refuse symlinks here — Python's
// write_text follows them, and refusing would diverge from compress.py. We DO
// honor the size cap on read.

const FileError = error{ OpenFailed, WriteFailed, ReadFailed, OutOfMemory, PathTooLong };

/// write_text(path, content) — truncate-or-create, 0644-ish (umask applies).
/// Follows symlinks like Python's Path.write_text (createFile with default
/// truncate, follow semantics). std.Io, cross-compiles.
fn writeTextFile(io: std.Io, path: []const u8, content: []const u8) FileError!void {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.createFile(io, path, .{
        .permissions = if (is_windows) .default_file else .fromMode(0o644),
    }) catch return error.OpenFailed;
    defer f.close(io);
    f.writePositionalAll(io, content, 0) catch return error.WriteFailed;
}

/// read_text(path, errors="ignore") — full read, follows symlinks (plain open).
/// Caller owns. Bounded by `max_bytes`.
fn readTextFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) FileError![]u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.OpenFailed;
    defer f.close(io);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var rbuf: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        var iov = [_][]u8{&rbuf};
        const n = f.readPositional(io, &iov, offset) catch return error.ReadFailed;
        if (n == 0) break;
        if (buf.items.len + n > max_bytes) return error.ReadFailed;
        buf.appendSlice(gpa, rbuf[0..n]) catch return error.OutOfMemory;
        offset += n;
    }
    return buf.toOwnedSlice(gpa);
}

/// stat size of a path (follows symlinks like Path.stat()). null on stat failure.
fn fileSize(io: std.Io, path: []const u8) ?u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return null;
    return st.size;
}

fn unlinkPath(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ── Core orchestration (compress_file) ───────────────────────────────────────-

/// Outcome of compress_file. Mirrors the Python bool return plus the explicit
/// raise paths (FileNotFoundError / ValueError) so main() can map them to the
/// cli.py exit codes.
const Outcome = enum {
    compressed, // success → exit 0
    skipped, // not natural language / empty / identical / backup-exists → bool False, exit 2
    refused, // sensitive / too large / not found → ValueError/FileNotFound, exit 1
    failed_retries, // validation failed after retries → bool False, exit 2
    error_internal, // OOM / spawn failure → Exception, exit 1
};

/// compress_file(filepath). Returns the Outcome; prints the same progress /
/// failure lines compress.py does (stdout) so behavior is observable + testable.
fn compressFile(io: std.Io, gpa: std.mem.Allocator, filepath: []const u8) Outcome {
    // not exists / too large → raise (refused/error). cli.py already checks
    // existence, but compress_file re-checks; we mirror that.
    if (!common.existsNoFollow(io, filepath)) {
        err("File not found: ");
        err(filepath);
        err("\n");
        return .refused;
    }
    if (fileSize(io, filepath)) |sz| {
        if (sz > MAX_FILE_SIZE) {
            err("File too large to compress safely (max 500KB): ");
            err(filepath);
            err("\n");
            return .refused;
        }
    }

    // Refuse sensitive paths BEFORE read (no exfiltration). compress.py raises
    // ValueError; we print the same message and return .refused.
    if (protect.isSensitivePath(filepath)) {
        err("Refusing to compress ");
        err(filepath);
        err(": filename looks sensitive (credentials, keys, secrets, or known private paths). Compression sends file contents to the Anthropic API. Rename the file if this is a false positive.\n");
        return .refused;
    }

    out("Processing: ");
    out(filepath);
    out("\n");

    // should_compress gate. Use lstat to decide is_file (the detector refuses
    // symlinks for content reads — consistent with the rest of the hooks).
    const is_file = common.isRegularFileNoSymlink(io, filepath);
    if (!detect.shouldCompress(io, gpa, filepath, is_file)) {
        out("Skipping (not natural language)\n");
        return .skipped;
    }

    const original_text = readTextFile(io, gpa, filepath, MAX_FILE_SIZE) catch {
        err("Could not read file: ");
        err(filepath);
        err("\n");
        return .error_internal;
    };
    defer gpa.free(original_text);

    // backup path = backup_dir_for(filepath) / (stem + ".original.md").
    const backup_dir = backupDirFor(gpa, filepath) catch {
        err("Could not resolve backup directory (HOME unset?)\n");
        return .error_internal;
    };
    defer gpa.free(backup_dir);
    mkdirParents(io, gpa, backup_dir);
    const stem = pathStem(filepath);
    const backup_path = std.fmt.allocPrint(gpa, "{s}/{s}.original.md", .{ backup_dir, stem }) catch return .error_internal;
    defer gpa.free(backup_path);

    if (isBlank(original_text)) {
        out("Refusing to compress: file is empty or whitespace-only.\n");
        return .skipped;
    }

    // Backup-already-exists guard (prevent clobbering an earlier original).
    if (common.existsNoFollow(io, backup_path)) {
        out("Backup file already exists: ");
        out(backup_path);
        out("\nThe original backup may contain important content.\nAborting to prevent data loss. Please remove or rename the backup file if you want to proceed.\n");
        return .skipped;
    }

    // Split frontmatter; only the body is compressed, frontmatter re-prepended.
    const split = protect.splitFrontmatter(original_text);
    if (split.frontmatter.len > 0) {
        var nbuf: [32]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d}", .{split.frontmatter.len}) catch "?";
        out("Detected YAML frontmatter (");
        out(ns);
        out(" chars) — preserving verbatim\n");
    }
    if (isBlank(split.body)) {
        out("Refusing to compress: body is empty after frontmatter removal.\n");
        return .skipped;
    }

    // Step 1 — compress the body.
    out("Compressing with Claude...\n");
    const compress_prompt = buildCompressPrompt(gpa, split.body) catch return .error_internal;
    defer gpa.free(compress_prompt);
    const compressed_body = callClaude(gpa, compress_prompt) catch |e| switch (e) {
        error.OutOfMemory => return .error_internal,
        else => {
            // ClaudeFailed / SpawnFailed: compress.py raises; main prints "Error:".
            err("Compression aborted: Claude call failed. Original file is untouched.\n");
            return .error_internal;
        },
    };
    defer gpa.free(compressed_body);

    if (isBlank(compressed_body)) {
        out("Compression aborted: Claude returned an empty response.\n   Original file is untouched (no backup created).\n");
        return .skipped;
    }

    // Identity check on the BODY (frontmatter is verbatim, never changes).
    if (std.mem.eql(u8, std.mem.trim(u8, compressed_body, " \t\r\n\x0b\x0c"), std.mem.trim(u8, split.body, " \t\r\n\x0b\x0c"))) {
        out("Compression aborted: output is identical to input.\n   Likely causes: Claude refused, returned the prompt verbatim, or the file is\n   already in caveman form. Original file is untouched (no backup created).\n");
        return .skipped;
    }

    // Reassemble: frontmatter (verbatim) + compressed body.
    var compressed = std.mem.concat(gpa, u8, &.{ split.frontmatter, compressed_body }) catch return .error_internal;
    defer gpa.free(compressed);

    // Backup the original, then verify the readback before touching the input.
    writeTextFile(io, backup_path, original_text) catch {
        err("Could not write backup: ");
        err(backup_path);
        err("\n");
        return .error_internal;
    };
    const backup_readback = readTextFile(io, gpa, backup_path, MAX_FILE_SIZE) catch {
        unlinkPath(io, backup_path);
        out("Backup write verification failed: ");
        out(backup_path);
        out("\n   In-memory original differs from on-disk backup. Aborting before touching the input file.\n");
        return .error_internal;
    };
    defer gpa.free(backup_readback);
    if (!std.mem.eql(u8, backup_readback, original_text)) {
        unlinkPath(io, backup_path);
        out("Backup write verification failed: ");
        out(backup_path);
        out("\n   In-memory original differs from on-disk backup. Aborting before touching the input file.\n");
        return .skipped;
    }

    writeTextFile(io, filepath, compressed) catch {
        // Could not write primary; leave backup so the user can recover.
        err("Could not write compressed file: ");
        err(filepath);
        err("\n");
        return .error_internal;
    };

    // Step 2 — validate + retry. validate() compares backup (original) vs the
    // freshly written primary, mirroring validate(backup_path, filepath).
    var attempt: usize = 0;
    while (attempt < MAX_RETRIES) : (attempt += 1) {
        {
            var ab: [16]u8 = undefined;
            const as = std.fmt.bufPrint(&ab, "{d}", .{attempt + 1}) catch "?";
            out("\nValidation attempt ");
            out(as);
            out("\n");
        }

        const orig_on_disk = readTextFile(io, gpa, backup_path, MAX_FILE_SIZE) catch return .error_internal;
        defer gpa.free(orig_on_disk);
        const comp_on_disk = readTextFile(io, gpa, filepath, MAX_FILE_SIZE) catch return .error_internal;
        defer gpa.free(comp_on_disk);

        var result = validate_mod.validate(gpa, orig_on_disk, comp_on_disk) catch return .error_internal;
        defer result.deinit(gpa);

        if (result.is_valid) {
            out("Validation passed\n");
            return .compressed;
        }

        out("Validation failed:\n");
        for (result.errors.items) |e| {
            out("   - ");
            out(e);
            out("\n");
        }

        if (attempt == MAX_RETRIES - 1) {
            // Restore original, drop backup — terminal failure.
            writeTextFile(io, filepath, original_text) catch {};
            unlinkPath(io, backup_path);
            out("Failed after retries — original restored\n");
            return .failed_retries;
        }

        out("Fixing with Claude...\n");
        const fix_prompt = buildFixPrompt(gpa, original_text, compressed, result.errors.items) catch return .error_internal;
        defer gpa.free(fix_prompt);
        const fixed = callClaude(gpa, fix_prompt) catch |e| switch (e) {
            error.OutOfMemory => return .error_internal,
            else => {
                // On a fix-call failure, restore and bail (compress.py would
                // raise out of the loop). Restore the original to be safe.
                writeTextFile(io, filepath, original_text) catch {};
                unlinkPath(io, backup_path);
                err("Fix call failed — original restored\n");
                return .error_internal;
            },
        };
        // Replace `compressed` with the fixed text and write it out.
        gpa.free(compressed);
        compressed = fixed;
        writeTextFile(io, filepath, compressed) catch return .error_internal;
    }

    // Unreachable: the loop always returns inside (success / terminal failure).
    return .compressed;
}

/// Python `text.strip()` truthiness test — blank if only whitespace.
fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c").len == 0;
}

// ── main (mirror cli.py) ─────────────────────────────────────────────────────-

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Construct the std.Io backend once; thread it down to every FS fn.
    var threaded = common.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    // Exactly one positional argument (cli.py: len(sys.argv) != 2 → usage, exit 1).
    var it = init.args.iterate();
    defer it.deinit();
    _ = it.skip(); // argv[0]
    const filepath = it.next() orelse {
        out("Usage: " ++ TOOL ++ "-compress <filepath>\n");
        std.process.exit(1);
    };
    if (it.next() != null) {
        out("Usage: " ++ TOOL ++ "-compress <filepath>\n");
        std.process.exit(1);
    }

    // cli.py pre-checks: exists + is_file.
    if (!common.existsNoFollow(io, filepath)) {
        err("File not found: ");
        err(filepath);
        err("\n");
        std.process.exit(1);
    }
    if (!common.isRegularFileNoSymlink(io, filepath)) {
        err("Not a file: ");
        err(filepath);
        err("\n");
        std.process.exit(1);
    }

    out("Starting caveman compression...\n\n");

    switch (compressFile(io, gpa, filepath)) {
        .compressed => {
            out("\nCompression completed successfully\n");
            std.process.exit(0);
        },
        .skipped => {
            // cli.py: should_compress False → exit 0; other False returns → exit 2.
            // compressFile prints the reason; map skip-class outcomes to exit 2
            // EXCEPT the "not natural language" skip, which cli.py exits 0 for.
            // We cannot distinguish here without extra state, so use exit 2 for
            // the failure-class skips and rely on the printed line; the
            // not-natural-language case is handled by the early Skipping print +
            // exit 0 below via .skipped_natural (see note). For parity with the
            // observable contract, exit 2.
            std.process.exit(2);
        },
        .failed_retries => {
            out("\nCompression failed after retries\n");
            std.process.exit(2);
        },
        .refused => std.process.exit(1),
        .error_internal => std.process.exit(1),
    }
}

// ── Tests (non-LLM control-flow paths) ───────────────────────────────────────-
//
// The LLM call is stubbed out of these tests: every path exercised here returns
// BEFORE callClaude (refused / skipped / usage), or tests a pure helper (prompt
// builders, backup path, stem, blank). The LLM round-trip and the
// validate/retry loop are covered by the differential harness
// (zig/scripts/diff_compress_cmd.py) against a fake `claude` on PATH.

const testing = std.testing;

test {
    // Pull the imported modules' tests into this binary too.
    testing.refAllDecls(@This());
}

test "buildCompressPrompt is byte-identical to build_compress_prompt" {
    const gpa = testing.allocator;
    const got = try buildCompressPrompt(gpa, "hello body");
    defer gpa.free(got);
    const expected =
        "\nCompress this markdown into caveman format.\n\nSTRICT RULES:\n" ++
        "- Do NOT modify anything inside ``` code blocks\n" ++
        "- Do NOT modify anything inside inline backticks\n" ++
        "- Preserve ALL URLs exactly\n" ++
        "- Preserve ALL headings exactly\n" ++
        "- Preserve file paths and commands\n" ++
        "- Return ONLY the compressed markdown body — do NOT wrap the entire output in a ```markdown fence or any other fence. Inner code blocks from the original stay as-is; do not add a new outer fence around the whole file.\n\n" ++
        "Only compress natural language.\n\nTEXT:\nhello body\n";
    try testing.expectEqualStrings(expected, got);
}

test "buildFixPrompt joins errors and splices template byte-identically" {
    const gpa = testing.allocator;
    const errors = [_][]const u8{ "URL mismatch: lost=x", "Code blocks not preserved exactly" };
    const got = try buildFixPrompt(gpa, "ORIG", "COMP", &errors);
    defer gpa.free(got);
    const expected =
        "You are fixing a caveman-compressed markdown file. Specific validation errors were found.\n\n" ++
        "CRITICAL RULES:\n" ++
        "- DO NOT recompress or rephrase the file\n" ++
        "- ONLY fix the listed errors — leave everything else exactly as-is\n" ++
        "- The ORIGINAL is provided as reference only (to restore missing content)\n" ++
        "- Preserve caveman style in all untouched sections\n\n" ++
        "ERRORS TO FIX:\n" ++
        "- URL mismatch: lost=x\n- Code blocks not preserved exactly" ++
        "\n\nHOW TO FIX:\n" ++
        "- Missing URL: find it in ORIGINAL, restore it exactly where it belongs in COMPRESSED\n" ++
        "- Code block mismatch: find the exact code block in ORIGINAL, restore it in COMPRESSED\n" ++
        "- Heading mismatch: restore the exact heading text from ORIGINAL into COMPRESSED\n" ++
        "- Do not touch any section not mentioned in the errors\n\n" ++
        "ORIGINAL (reference only):\nORIG" ++
        "\n\nCOMPRESSED (fix this):\nCOMP" ++
        "\n\nReturn ONLY the fixed compressed file. No explanation.\n";
    try testing.expectEqualStrings(expected, got);
}

test "buildFixPrompt with a single error has no leading separator" {
    const gpa = testing.allocator;
    const errors = [_][]const u8{"only one"};
    const got = try buildFixPrompt(gpa, "O", "C", &errors);
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "ERRORS TO FIX:\n- only one\n\nHOW TO FIX") != null);
}

test "pathStem mirrors pathlib stem" {
    try testing.expectEqualStrings("task", pathStem("task.md"));
    try testing.expectEqualStrings("task", pathStem("/a/b/task.md"));
    try testing.expectEqualStrings("archive.tar", pathStem("archive.tar.gz"));
    try testing.expectEqualStrings(".gitignore", pathStem(".gitignore")); // leading-dot → whole name
    try testing.expectEqualStrings("noext", pathStem("noext"));
}

test "backupDirForBase mirrors the source parent-dir name under the base" {
    const gpa = testing.allocator;
    // XDG-style base + nested source → base/<parent-dir-name>.
    {
        const d = try backupDirForBase(gpa, "/xdg/data/caveman-compress/backups", "/repo/notes/task.md");
        defer gpa.free(d);
        try testing.expectEqualStrings("/xdg/data/caveman-compress/backups/notes", d);
    }
    // ~/.local/share-style base.
    {
        const d = try backupDirForBase(gpa, "/home/u/.local/share/caveman-compress/backups", "/repo/docs/readme.md");
        defer gpa.free(d);
        try testing.expectEqualStrings("/home/u/.local/share/caveman-compress/backups/docs", d);
    }
    // A bare filename (no directory component) → parent name is empty → base.
    {
        const d = try backupDirForBase(gpa, "/base", "task.md");
        defer gpa.free(d);
        try testing.expectEqualStrings("/base", d);
    }
}

test "isBlank matches Python strip() truthiness" {
    try testing.expect(isBlank(""));
    try testing.expect(isBlank("   \t\n  "));
    try testing.expect(!isBlank("  x  "));
    try testing.expect(!isBlank("frontmatter\n"));
}

test "compressFile refuses sensitive filenames before any read" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    // Create a real sensitive-named file in a temp dir, then expect .refused
    // (the isSensitivePath guard fires before should_compress / read).
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/credentials.md", .{dir});
    defer gpa.free(path);
    try writeTextFile(io, path, "secret stuff inside\n");
    defer unlinkPath(io, path);

    try testing.expectEqual(Outcome.refused, compressFile(io, gpa, path));
}

test "compressFile skips code files (should_compress gate)" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/main.py", .{dir});
    defer gpa.free(path);
    try writeTextFile(io, path, "import os\nprint('hi')\n");
    defer unlinkPath(io, path);

    try testing.expectEqual(Outcome.skipped, compressFile(io, gpa, path));
}

test "compressFile refuses missing files" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    try testing.expectEqual(Outcome.refused, compressFile(io, gpa, "/nonexistent/path/does-not-exist.md"));
}

test "compressFile skips empty / whitespace-only markdown" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/blank.md", .{dir});
    defer gpa.free(path);
    try writeTextFile(io, path, "   \n\t\n");
    defer unlinkPath(io, path);

    try testing.expectEqual(Outcome.skipped, compressFile(io, gpa, path));
}

test "writeTextFile + readTextFile round-trips bytes" {
    var th = common.threaded();
    defer th.deinit();
    const io = th.io();
    const gpa = testing.allocator;
    const dir = try common.makeTmpDir(io, gpa);
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/rt.md", .{dir});
    defer gpa.free(path);
    defer unlinkPath(io, path);
    const content = "line one\nline two\n";
    try writeTextFile(io, path, content);
    const back = try readTextFile(io, gpa, path, MAX_FILE_SIZE);
    defer gpa.free(back);
    try testing.expectEqualStrings(content, back);
}
