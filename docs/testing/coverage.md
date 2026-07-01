# Coverage & test toolchain

## Quick start

```sh
nix develop                       # kcov + zig + bun + python (coverage)
cd zig
zig build test -Dtool=caveman                     # run tests (no coverage)
zig build test -Dtool=caveman -Dtest-coverage     # run under kcov
#   → line+branch coverage in zig/zig-out/coverage/<binary>/
zig build coverage-merge -Dtest-coverage          # merge per-binary reports
```

## How `-Dtest-coverage` works

`zig/build.zig` defines a `-Dtest-coverage` bool option. When set, every test
artifact is run under **kcov** instead of directly (`CoverageCtx.run`):

```
kcov --clean --include-pattern=/src/ --exclude-pattern=<zig-noexec> OUT_DIR TEST_BIN
```

- `--include-pattern=/src/` restricts coverage to our source, not std.
- `--exclude-pattern` drops Zig constructs that must never execute
  (`unreachable`, `@panic`, `@compileError`, `SkipZigTest`) so they don't count
  as uncovered lines. kcov has no Zig awareness, so this is pattern-based.
- kcov returns the wrapped program's exit code, so a failing test still fails the
  build — coverage runs are not a softer gate.
- With coverage **off**, `covRun` is a plain `RunArtifact`: zero behavior change
  for the normal `zig build test`.

The 7 test roots (main bins, compress-protect, compress-cmd, the three claw
lib-roots + claw aggregate, install) each emit a report under
`zig-out/coverage/<name>/`; `coverage-merge` aggregates them.

## Toolchain provisioning

`flake.nix` pins kcov + zig + bun + python(coverage) in a devShell. The
self-hosted CI runners consume the **same** devShell, so local and CI coverage
are byte-identical. JS mutation (Stryker) and Python mutation (cosmic-ray) run
through `bunx` / `pixi` per repo tooling policy.

## Environment note (honest status)

The `-Dtest-coverage` wiring is verified to: (a) leave the normal `zig build
test` path unchanged (exit 0), (b) configure all kcov run-steps + the
`coverage-merge` step when enabled, and (c) **fail loudly** when kcov is absent
(no silent fake-success). The **green coverage numbers** are produced where kcov
is on PATH — the CI runners (`nix develop`) or any dev machine that ran
`nix develop`. In sandboxes without GitHub API access, `nix` cannot resolve the
nixpkgs flake input, so kcov can't be fetched and the coverage *run* (not the
wiring) is deferred to CI. This is recorded so a green local `zig build test`
without `-Dtest-coverage` is never mistaken for a coverage pass.
