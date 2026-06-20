# caveman Zig hook (PoC)

Native Zig reimplementation of the `UserPromptSubmit` hook that today ships as
`src/hooks/caveman-mode-tracker.js`. One Zig source, `-Dtool`-parameterized, so
the same codebase builds the `caveman-hook` and `ponytail-hook` binaries.

## Why

The Node hook needs a Node runtime resolved and an ES-module/CJS dance on every
turn (see `src/hooks/package.json`). A static binary drops that: no interpreter
spawn, no `package.json` type resolution, no `node_modules`. The hook fires once
per prompt — the per-turn cost is worth removing.

## What it does

Identical contract to the JS mode-tracker's slash-command path:

1. Reads the hook JSON event on stdin.
2. Parses `prompt` via `std.json` (not hand-rolled).
3. Matches `/<tool> <level>` → mode (`/caveman` → `full`, `/caveman ultra` →
   `ultra`, `/caveman wenyan` → `wenyan-full` alias, etc.). Whitelist-validated
   against `VALID_MODES`; anything off-list is rejected (injection-safe).
4. Persists the mode through a **symlink-safe** flag write (the security core).
5. Emits the `hookSpecificOutput` JSON the harness injects as per-turn
   reinforcement.

## Security: reimplements `safeWriteFlag`

Faithful port of `safeWriteFlag` from `src/hooks/caveman-config.js`. The flag
write:

- refuses to follow a symlink at the target path **or** its parent directory
  (`lstat` + `S_IFLNK` check),
- opens the temp file with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW`, mode
  `0600`,
- writes, then **atomically renames** temp → target,
- unlinks the temp on rename failure,
- silent-fails on any filesystem error (never blocks the turn).

A local attacker who pre-plants a symlink at the predictable flag path
(`$CLAUDE_CONFIG_DIR/.caveman-active`) cannot redirect the write onto e.g.
`~/.ssh/authorized_keys`. Test `safeWriteFlag refuses symlinked target (clobber
attack)` proves the SECRET victim file is untouched.

## Build

```sh
zig build -Dtool=caveman                      # debug
zig build -Dtool=caveman -Doptimize=ReleaseSmall   # shipping binary
```

Output: `zig-out/bin/caveman-hook`. Pass `-Dtool=ponytail` for the sibling
binary from the same source.

## Verified numbers

Measured on this machine with Zig `0.16.0-dev` (see `build.zig.zon`
`minimum_zig_version = "0.16.0"`):

| Metric | Value |
|--------|-------|
| Binary size (ReleaseSmall, links libc) | 200,752 bytes (~196 KB) static |
| Cold start | ~3 ms measured (hyperfine, 200 runs); ~18 ms ceiling including process spawn on a busy host |
| Unit tests | 5/5 pass (`zig build test -Dtool=caveman`) |

The five tests cover: `isValidMode` whitelist (rejects `rm -rf /`,
`../../etc/passwd`, empty), `parseSlashMode` (bare/level/`wenyan` alias/garbage),
`extractPrompt` (valid JSON + non-JSON), the symlink clobber-refusal, and a
clean-path write round-trip.

## Status

Proof of concept. Pinned to the stable libc C ABI (`std.c` + two `extern`
decls) rather than the in-flight `std.Io` surface — a hook binary links libc
anyway, and this keeps the PoC on a stable interface. Production rewrite can
migrate to `std.Io` once 0.16 stabilizes; the security logic is identical.
