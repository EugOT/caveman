# Comprehensive Test & Coverage Architecture — caveman

**Date:** 2026-06-22
**Status:** Approved design → investigation fan-out → task backlog
**Goal:** Drive the entire caveman repository to **100% meaningful test coverage** across unit, functional, regression, e2e, differential, and mutation test classes — where "meaningful" is enforced by a mutation-kill gate, not line coverage alone.

---

## 1. Context & constraints

The repo is mid-migration: a JS+Python implementation is being rewritten to Zig (R1–R6a merged to `dev`; R6b — ship Zig binaries + retire JS/Py — pending). Surface as of 2026-06-22:

| Language | Files | LOC | Role |
|---|---|---|---|
| Zig | 19 (`zig/src/*.zig`) | 13,408 | **Primary** — the future of the codebase |
| JS | 15 (`src/`, `bin/`) | 5,189 | Source-of-truth being retired (R6b); some shims survive |
| Python | 7 (`skills/caveman-compress/scripts`) | 853 | compress pipeline, retiring |
| Shell / PS1 | 8 | — | install shims + statusline |

Existing tests: 216 Zig in-source `test {}` blocks across 18 files; assorted `tests/*.js` / `tests/*.py`; `tests/installer/*.test.mjs` wired to `npm test`. **No CI runs any test. No coverage or mutation tooling exists.**

### Locked decisions (from brainstorming)

1. **Zig-first.** Drive Zig to 100% meaningful coverage. JS/Python kept only as **differential oracles** proving Zig matches them byte-for-byte; not chased to 100% (they're retiring). Shims that survive R6b (opencode plugin `.mjs`, pi-extension, `install.sh`) get the full Zig-tier gate.
2. **Coverage gate = line+branch AND mutation score.** A test that executes a line but kills no mutant is theater.
3. **CI enforcement on self-hosted Actions runners** (the existing `forgejo-runners`/k3s infra). 100% is durable, not a one-time snapshot.
4. **Multi-agent workflow fan-out** drives the per-file investigation.

---

## 2. Test taxonomy (six classes)

| Class | Definition (this repo) | Location | Tooling |
|---|---|---|---|
| **Unit** | Pure-logic fns in isolation: mode parse/canonicalize, JSON field extract, frontmatter split, path resolution, validation byte-scanners, JSONC settings merge, prompt builders | Zig in-source `test {}` per module | `zig build test` + kcov |
| **Functional** | A whole binary driven via stdin/argv/env asserting stdout/flag/file effects | `tests/functional/` (Zig harness + bash) driving `zig-out/bin/*` | built binaries + bash |
| **Regression** | One locked test per **fixed bug**, keyed to its commit SHA, so the bug can never silently return | `tests/regression/` (Zig + shell) | `zig build test` + harness |
| **E2E** | Full install→activate→use→uninstall lifecycle on throwaway `HOME`/`CLAUDE_CONFIG_DIR`, across the agent matrix | `tests/e2e/*.sh` | bash + real binaries, sandboxed |
| **Differential** (oracle) | Zig output ≡ JS/Python source-of-truth, byte-for-byte, on shared fixtures — the bridge that lets JS/Py be retired with confidence | `tests/differential/` | run both, `diff` |
| **Mutation** | Inject operator mutations; confirm a test kills each. The "meaningful" gate. | `tooling/mutate/` | Zig: custom harness; JS: Stryker; Py: cosmic-ray |

---

## 3. Coverage gates

| Lang | Line+branch | Mutation | Gate (blocking?) |
|---|---|---|---|
| **Zig** | **kcov** (`-Dtest-coverage`; fork or `--exclude-line`/`--exclude-pattern` for `unreachable`/`@panic`/`else => unreachable`) | **custom harness** `tooling/mutate/zig-mutate` | **100% line+branch; ≥90% mutation kill, every survivor triaged** — BLOCKING |
| **JS** | **c8** (`bunx c8`) | **Stryker** (`bunx stryker`) | Differential-parity blocking; line+mutation tracked, **non-blocking** (retiring). Surviving shims → full Zig-tier gate. |
| **Python** | **coverage.py** (pixi) | **cosmic-ray** (pixi) | Same as JS — oracle + parity, non-blocking. |
| **Shell/PS1** | bashcov/kcov (bash); manual (PS1) | n/a | Functional+e2e of every path; no mutation. |

### Mutation operators (Zig harness)

Relational `==`↔`!=`, `<`↔`<=`↔`>`↔`>=`; boolean `and`↔`or`; literal `return true`↔`return false`; arithmetic `+`↔`-`; statement deletion; small constant tweak (`0`→`1`, `+1`→`-1`); `orelse` branch swap. Apply one mutation at a time to a copy of `zig/src/*.zig`, run `zig build test`, record survive/kill.

### "Meaningful" definition

A line is covered iff a test **asserts** behavior such that mutating that line fails a test. Mutation survivors are the worklist: each is a missing assertion → fixed with a new test, or annotated `// mutation-equivalent: <reason>` (read by the harness to exclude from the denominator — honest kill-rate, not gamed).

### Equivalence-mutant discipline

Genuinely unkillable survivors (debug-only log, defensive `else => unreachable`, platform-gated dead branch on the build target) get an inline `// mutation-equivalent:` annotation with justification. Annotations are reviewed like code.

---

## 4. CI enforcement

New `.github/workflows/test-coverage.yml`, `runs-on: [self-hosted, …]`, on PRs to `dev`/`main`:

1. **Build matrix** — `zig build -Dtool={caveman,ponytail}` native + cross (linux/arm; windows allowed-fail until R6-Windows). Fail on any non-deferred error.
2. **Test** — `zig build test` (both tools) · `bun test` (JS) · `pixi run pytest` (Python) · `tests/e2e/*.sh` · `tests/differential/*`.
3. **Coverage** — kcov + c8 + coverage.py → merged report → fail under threshold.
4. **Mutation** — Zig harness + Stryker + cosmic-ray. Full run nightly / `workflow_dispatch`; PR runs mutation **only on changed files** for speed.
5. **Artifacts** — HTML coverage + mutation report uploaded; optionally published to report_host `100.100.39.44:4000/r/<slug>`.

---

## 5. Investigation fan-out → task backlog

A multi-agent workflow runs one **read-only** agent per source module (~30 files). Each emits a structured per-file manifest:

- every public fn + branch + error path → required **unit** tests
- binary-level behaviors → **functional** tests
- fixed bugs in that file (from `git log` `fix(...)` commits, §6) → **regression** tests keyed to SHA
- lifecycle touchpoints → **e2e** tests
- JS/Py counterpart → **differential** oracle pairs
- mutation operators that *should* be killed → **mutation** targets
- **already-covered** by the 216 Zig tests + `tests/*` → so we add only gaps

A synthesis pass dedupes, maps each test → coverage/mutation target, and emits the **master test list**. Each cluster (module × class) becomes one task, blocked-by the tooling-setup tasks.

### Tooling-setup tasks (prerequisites, block everything)

- T0.1 kcov + `-Dtest-coverage` in `build.zig` (+ exclude rules for `unreachable`/`@panic`)
- T0.2 `tooling/mutate/zig-mutate` harness (operators above, equivalence-annotation reader)
- T0.3 `bunx` Stryker + c8 config (JS)
- T0.4 pixi `cosmic-ray` + coverage.py config (Python)
- T0.5 `tests/{functional,regression,e2e,differential}/` scaffolding + a single `just`/`bun` test entrypoint
- T0.6 `.github/workflows/test-coverage.yml` on self-hosted runners

---

## 6. Regression-test keys (fixed-bug commits)

Each gets a locked test that fails on the pre-fix code:

| Commit | Bug guarded |
|---|---|
| `83d5e60` | O_APPEND concurrency — stats history torn under concurrent writers |
| `81e56ed` | symlink guard must honor configured agent roots (XDG/opencode/openclaw/nullclaw) |
| `dc8ecb5` | per-turn reinforcement on plain prompts + `/caveman-stats` routing |
| `5560b8a` | post-review safety hardening |
| `00755c7` | `safeWriteFlag` ≡ JS source-of-truth |
| `a7f78fa` | refuse symlinked ANCESTOR dirs |
| `cf57f40` | validate `-Dtool`, exact token match, silent-fail |
| `a031d88` | repo-local init guard |
| `ddf2121` / `22f75e3` | opencode plugin loads in compiled Bun runtime + lifecycle hooks |
| `46de578` | XSS — escape user input in demo terminal |
| `f68111a` | stats Opus price + Windows statusline UTF-8 |
| `e8eae0f` | compress utf-8 pin, Windows `.cmd` resolve, frontmatter + backup-dir |
| (first-run flag-drop, leaf-symlink-clobber, uid-symlink-parent — from R6a) | covered by existing `.active`/`.active2`/`.active3` tests; promote to named regression tests |

---

## 7. Success criteria

- `zig build test` (caveman + ponytail): 100% line+branch via kcov; ≥90% mutation kill, every survivor triaged.
- Differential suite: Zig ≡ JS/Py byte-for-byte on every shared fixture.
- E2E lifecycle green for every agent in the install matrix.
- CI workflow enforces all gates on self-hosted runners; PRs fail below threshold.
- Every fixed bug in §6 has a named regression test that fails on the pre-fix code (proven, like the O_APPEND test).
- Master test list fully decomposed into tasks; backlog complete.
