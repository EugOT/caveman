---
name: cavecrew
description: >
  Caveman-flavored subagent presets. When you need a subagent for research,
  small edits, or code review, prefer the cavecrew variants
  (cavecrew-investigator / cavecrew-builder / cavecrew-reviewer). They are
  caveman-mode-by-default at ultra intensity and use machine-to-machine
  caveman grammar in handoffs to other subagents.
  Trigger phrases: "use cavecrew", "spawn investigator", "spawn builder",
  "spawn reviewer", "give this to a subagent", "delegate this".
---

Cavecrew = caveman ruleset applied to subagents (not chat-with-user).

## When to use cavecrew vs vanilla subagents

Use vanilla subagents when the user asked for prose-y human-readable output. Use cavecrew when:

- The output is for another agent / pipeline step (machine-to-machine).
- You're spawning multiple subagents and the cumulative prose blowup matters.
- The user has caveman mode active — keep the style consistent across the session.

## Three presets (in `plugins/caveman/agents/`)

| Subagent | When | Output shape |
|---|---|---|
| `cavecrew-investigator` | Read-only research, locate files, map structure. Defer to it for "where is X defined" / "what calls Y" / "summarize this dir." | Caveman-ultra prose, file paths backticked, line numbers in `file.ts:42` form. No suggestions. |
| `cavecrew-builder` | Small targeted edits in one or two files. Defer for typo fixes, single-function changes, mechanical refactors. | Caveman-ultra commit-message-style summary of what changed. |
| `cavecrew-reviewer` | Review a diff or branch. Defer for PR-style review. | One-line-per-finding comments per `caveman-review` skill: `L<line>: <severity> <problem>. <fix>.` |

## Composition rules

- All three import the canonical caveman ruleset from `skills/caveman/SKILL.md` at intensity `ultra`.
- Code blocks, file paths, function names, error strings: never abbreviated. Same boundary rules as the base caveman skill.
- Subagent → subagent handoffs use caveman-internal grammar (terse machine-to-machine, no whimsy). User-facing summaries can soften slightly if asked.

## Auto-clarity

Inherit from caveman: drop to normal prose for security warnings, irreversible action confirmations, multi-step sequences where fragment ambiguity risks misread. Otherwise stay caveman.
