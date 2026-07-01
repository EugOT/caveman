# End-to-end tests

Full lifecycle on a throwaway HOME/CLAUDE_CONFIG_DIR: install → activate → use →
uninstall, and the compress pipeline (detect → compress → validate → backup →
restore) on real files. Use the sandbox helper. Run: `tests/run-all.sh e2e`.
