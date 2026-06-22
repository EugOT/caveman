# zig-mutate — mutation testing for the meaningful-coverage gate

No off-the-shelf Zig mutation-testing tool exists (verified 2025–2026), so this
is a purpose-built, minimal engine. It is what makes "100% coverage" *meaningful*:
a line is only truly covered if a test **asserts** its behavior such that mutating
it makes a test fail.

## Parts

- **`mutate.py`** — the mutation engine. Comment-, string-, and `test {}`-block
  aware (it mutates code-under-test, never the assertions or non-code bytes).
  Operators: `==`↔`!=`, `<`↔`<=`, `>`↔`>=`, `and`↔`or`, `return true`↔`return false`.
  - `mutate.py count FILE` → number of sites
  - `mutate.py list  FILE` → JSON `[{idx,line,col,op,from,to}]`
  - `mutate.py apply FILE IDX --out F` → write the mutated source
- **`zig-mutate`** — the runner. For each site: apply → run tests → classify
  KILLED / SURVIVED / EQUIVALENT → restore. Always restores the original (trap on
  EXIT/INT/TERM). Exits non-zero below the 90% gate.

## Usage

```sh
# whole-file, full build (slow, thorough — what CI runs):
tooling/mutate/zig-mutate zig/src/common.zig --tool caveman --json report.json

# fast iteration on one file with a per-file test cmd:
ZIG=$(which zig) tooling/mutate/zig-mutate zig/src/common.zig \
  --test-cmd "$ZIG test src/common.zig -lc" --limit 20 --json report.json
```

## Classification

| Result | Meaning | Action |
|---|---|---|
| **KILLED** | tests fail on the mutant | none — the line is meaningfully covered |
| **SURVIVED** | tests pass despite the mutant | **add a killing test** (the worklist) |
| **EQUIVALENT** | mutant is annotated `// mutation-equivalent:` | excluded from the denominator |

## Equivalence annotations

Some mutants are genuinely unkillable (a debug-only log, a defensive
`else => unreachable`, a comptime platform branch dead on the build target). Mark
the line (or the line above) with:

```zig
const is_windows = builtin.os.tag == .windows; // mutation-equivalent: comptime platform branch, single-target build can't observe the flip
```

The runner reads this and drops the mutant from the kill-rate denominator — so the
rate is honest, not gamed. Annotations are reviewed like code.

## Gate

`killed / (killed + survived) ≥ 90%`, **and every survivor triaged** (killed by a
new test or annotated equivalent). Wired into CI per task T0.6.
