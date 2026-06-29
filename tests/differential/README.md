# Differential (oracle) tests

Prove the Zig binary's output is byte-for-byte identical to its JS/Python
source-of-truth on shared fixtures — the bridge that lets JS/Py be retired (R6b).
Pattern: run both on the same input, `diff_eq`. Fixtures in `fixtures/`. Oracle
pairs are listed per cluster in the master plan. Run: `tests/run-all.sh differential`.
