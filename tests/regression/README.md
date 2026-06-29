# Regression tests

One locked test per **fixed bug**, keyed to its commit SHA, proven to FAIL on the
pre-fix code. Naming: `<module>__<short-desc>.test.sh`, with a header comment
`# guards <sha>: <bug>`. See the master plan regression cluster + the fix-commit
table in `docs/superpowers/specs/2026-06-22-comprehensive-test-coverage-design.md` §6.
The O_APPEND concurrency regression (commit 83d5e60) already has a proven test in
`zig/src/common.zig`. Run: `tests/run-all.sh regression`.
