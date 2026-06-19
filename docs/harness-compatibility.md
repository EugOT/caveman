# Harness compatibility

Caveman has two integration layers:

1. Native installers for agents with a stable plugin, extension, hook, or workspace-skill API.
2. Universal repo-local files for any agent that reads project rules or skills.

The universal layer is the fallback contract. `node bin/install.js --with-init --only <id>` writes `AGENTS.md` and `.agents/skills/caveman/SKILL.md` for every repo-local harness alias, then adds harness-specific files when caveman knows one.

## Universal contract

`AGENTS.md` is the canonical project rules file. Keep it concise and exact because many agents load it into every session. The matching project skill lives at `.agents/skills/caveman/SKILL.md`, the directory Warp recommends first and scans alongside `.claude/skills/`, `.codex/skills/`, `.opencode/skills/`, and other agent-specific skill folders.

Claude-compatible harnesses also get `CLAUDE.md` with an `@AGENTS.md` import, because Claude Code reads `CLAUDE.md` directly and documents `AGENTS.md` as an import target rather than a primary memory file.

## Harness routes

| Harness | Route |
| --- | --- |
| Claude Code / Claude Desktop | Claude plugin or repo-local `CLAUDE.md` import, `.claude/skills/caveman/SKILL.md`, `AGENTS.md`, `.agents/skills/caveman/SKILL.md` |
| Codex CLI / Codex app | `skills` profile plus repo-local `AGENTS.md`, `.agents/skills/caveman/SKILL.md`, `.codex/skills/caveman/SKILL.md` |
| opencode | Native plugin and global opencode files; repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md` via `--with-init` |
| Warp / Warp Preview | `skills` profile plus repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md` |
| OpenClaw | Native `--only openclaw` writes only the workspace skill and `SOUL.md`; `--with-init --only openclaw` also writes repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md` |
| NullClaw | Workspace skill with `always: true`; repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md` via `--with-init` |
| Pi | `AGENTS.md`, `.agents/skills/caveman/SKILL.md`, `.pi/skills/caveman/SKILL.md` |
| pz | `AGENTS.md`, `.agents/skills/caveman/SKILL.md`, `.pz/skills/caveman/SKILL.md` |
| walcode / walkode / claw / goclaw / zeroclaw | `AGENTS.md`, `.agents/skills/caveman/SKILL.md`, `.codex/skills/caveman/SKILL.md`, `.claw/instructions.md` |
| Antigravity app / CLI | `skills` profile plus repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md` |
| Perplexity / Hermes | Universal repo-local `AGENTS.md` and `.agents/skills/caveman/SKILL.md`; no native provider claim until a stable loader contract exists |

## Source checks

- [AGENTS.md](https://agents.md/): open Markdown format for repository instructions, no required fields, closest file wins.
- [Claude Code memory](https://code.claude.com/docs/en/memory): `CLAUDE.md` is the primary memory file; import `@AGENTS.md` to share one source of truth.
- [Warp rules](https://docs.warp.dev/agent-platform/capabilities/rules/) and [Warp skills](https://docs.warp.dev/agent-platform/capabilities/skills/): project rules default to uppercase `AGENTS.md`; project skills can live in `.agents/skills/`.
- [opencode rules](https://opencode.ai/docs/rules/) and [opencode plugins](https://opencode.ai/docs/plugins/): project rules use `AGENTS.md`; plugins load from project/global plugin directories and expose the `event` dispatcher. Caveman's `chat.message` and `experimental.chat.system.transform` hooks are guarded by installer tests.
