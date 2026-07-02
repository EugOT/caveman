/**
 * cpz-rewrite.workflow.ts — type-safe work-program for the caveman/ponytail/pz
 * (cpz) "from-first-principles" effort: merge stranded PRs, sync valuable upstream
 * ponytail work, and continue retiring the non-Zig surface per-harness.
 *
 * This file is the DECLARATIVE program spec (the requested deliverable). It is
 * lint/typecheck-able with `bunx tsc --noEmit workflows/cpz-rewrite.workflow.ts`
 * and `bunx @biomejs/biome check workflows/`. It does NOT execute agents itself;
 * the executable Workflow-tool scripts live under `.claude/*.workflow.js` and are
 * generated FROM the thread definitions below (one Codex prompt per thread).
 *
 * Ground truth captured 2026-06-27 (verified via gh/git, never assumed):
 *   caveman   fork→JuliusBrussee/caveman      41↑/0↓   | PR #13 OPEN, mergeable=false (dirty)
 *   ponytail  fork→DietrichGebert/ponytail     12↑/39↓  | 0 open PR; main feb5f80 JS 2660/Py 1473/Zig 2377
 *   pz        fork→joelreymont/pz              23↑/0↓   | PR #19, #20 OPEN, mergeable=clean
 *   nullclaw  fork→nullclaw/nullclaw           11↑/0↓
 *   cavekit   fork→JuliusBrussee/cavekit        0↑/2↓
 */

// ─────────────────────────────────────────────────────────────────────────────
// Types — strict ownership + dependency model
// ─────────────────────────────────────────────────────────────────────────────

/** A repository working tree on disk. */
type Repo = "caveman" | "ponytail" | "pz";

/** Risk class for a thread's actions. Gates escalate with risk. */
type Risk = "safe" | "review" | "unsafe";

/** Git ref / path a thread EXCLUSIVELY owns for the duration of its run. No two
 *  concurrently-runnable threads may share an owned path (enforced by assertNoOverlap). */
type OwnedPath = string;

/** A safety gate that must pass before a thread's output is accepted. */
interface Gate {
	readonly name: string;
	/** Shell command (run in the repo root) whose exit 0 == pass. */
	readonly cmd: string;
	/** When true, a human/owning-session must approve before the gate's action proceeds. */
	readonly requiresApproval: boolean;
}

/** One parallelizable unit of work, executed by an agent-team. */
interface Thread {
	readonly id: string;
	readonly repo: Repo;
	readonly title: string;
	readonly risk: Risk;
	/** Thread ids that must COMPLETE before this thread may start. */
	readonly dependsOn: readonly string[];
	/** Paths/refs this thread mutates exclusively. Enforced disjoint across siblings. */
	readonly owns: readonly OwnedPath[];
	/** Read-only inputs (no ownership, may overlap freely). */
	readonly inputs: readonly string[];
	/** Artifacts this thread produces (branches, files, PRs). */
	readonly outputs: readonly string[];
	/** External surfaces the thread is permitted to use. */
	readonly uses: readonly string[];
	/** Subagent roles the team lead spawns. */
	readonly subagents: readonly string[];
	/** Acceptance gates — ALL must pass, in order. */
	readonly gates: readonly Gate[];
	/** Acceptance criteria, human-readable. */
	readonly accept: readonly string[];
	/** The optimized Codex/agent prompt driving the thread (verbatim). */
	readonly prompt: string;
	/** Recorded blockers (precise, with the exact unblock command/access). */
	readonly blockers: readonly string[];
}

/** A wave of threads that run in parallel (a barrier between waves). */
interface Wave {
	readonly id: string;
	readonly title: string;
	readonly threads: readonly Thread[];
}

interface Program {
	readonly name: string;
	readonly model: "opus";
	readonly waves: readonly Wave[];
	/** Cross-cutting invariants every thread honors. */
	readonly invariants: readonly string[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared gates + invariants
// ─────────────────────────────────────────────────────────────────────────────

const ZIG = "/etc/profiles/per-user/etretiakov/bin/zig";
const ZIGLINT =
	"/Users/etretiakov/ghq/github.com/EugOT/ziglint/zig-out/bin/ziglint";
/** Pre-commit hook resolves `biome` here (bun global) so it does NOT fall back to
 *  `nix run nixpkgs#biome` (which 403s on api.github.com in-sandbox). Threads that
 *  commit JS/TS must have this on PATH. */
export const BUN_BIOME = "/Users/etretiakov/.cache/.bun/bin/biome";

function zigGate(repo: Repo, tool?: string): Gate[] {
	const t = tool ? ` -Dtool=${tool}` : "";
	const dir = repo === "pz" ? "." : "zig";
	return [
		{
			name: "zig build",
			cmd: `cd ${dir} && ${ZIG} build${t}`,
			requiresApproval: false,
		},
		{
			name: "zig build test",
			cmd: `cd ${dir} && ${ZIG} build test${t}`,
			requiresApproval: false,
		},
		{
			name: "zig fmt --check",
			cmd: `cd ${dir} && ${ZIG} fmt --check src/*.zig`,
			requiresApproval: false,
		},
	];
}

const INVARIANTS: readonly string[] = [
	"Never trust agent ok:true — the owning session independently re-runs every gate before committing.",
	"Installer scripts have outward side effects: NEVER run/source install.sh against the real env; sandbox HOME+CLAUDE_CONFIG_DIR + --dry-run.",
	"Verify std APIs via zigdoc before use (this is zig-0.16.0-dev.3142; many APIs moved).",
	"biome pre-commit hook needs `biome` on PATH (bun global) else it falls to `nix run nixpkgs#biome` which 403s in-sandbox.",
	"Branch policy: feature→dev PRs; only dev→main PRs; main is the production install source.",
	"Do NOT submit work upstream (user does not want PRs to JuliusBrussee/DietrichGebert/joelreymont).",
	"Preserve irreducible JS/ESM shims (pi-extension/index.js, .opencode/*.mjs) — these harnesses mandate JS.",
	"Mark every migration explicitly; never silently delete a tool/config; no destructive cleanup without an approval gate.",
	"All agent threads run on latest Opus (per workflows-use-latest-sonnet-or-opus).",
];

// ─────────────────────────────────────────────────────────────────────────────
// WAVE 1 — independent merges + read-only analysis (max parallelism, no shared paths)
// ─────────────────────────────────────────────────────────────────────────────

const T_caveman_pr13: Thread = {
	id: "caveman.pr13",
	repo: "caveman",
	title: "Rebase + merge caveman PR #13 (coverage tooling) onto dev",
	risk: "review",
	dependsOn: [],
	owns: ["caveman:branch:test/coverage-100-plan"],
	inputs: [
		"caveman:dev",
		"docs/superpowers/specs/2026-06-22-master-test-plan.json",
	],
	outputs: ["caveman PR #13 merged → dev"],
	uses: [
		"git rebase",
		"gh api pulls/merge",
		"zig build/test",
		"bunx c8/@stryker-mutator/core",
		"pixi",
	],
	subagents: ["conflict-resolver", "ci-verifier"],
	gates: [
		...zigGate("caveman", "caveman"),
		{
			name: "coverage tooling intact",
			cmd: "test -x tooling/mutate/zig-mutate && test -f flake.nix && test -f .github/workflows/test-coverage.yml",
			requiresApproval: false,
		},
		{
			name: "merge",
			cmd: "gh api repos/EugOT/caveman/pulls/13/merge -X PUT -f merge_method=merge",
			requiresApproval: true,
		},
	],
	accept: [
		"test/coverage-100-plan rebased on current dev; conflicts resolved keeping the T0.1-T0.6 tooling + R6 behavior.",
		"zig build + zig build test green; tooling/mutate, flake.nix, .github/workflows/test-coverage.yml present.",
		"PR #13 mergeable=clean then merged → dev.",
	],
	prompt:
		"PR #13 (test/coverage-100-plan → dev) is mergeable=false/dirty because R6 landed under it. Rebase the branch onto current origin/dev. The branch adds T0.1-T0.6 coverage tooling (kcov in build.zig, tooling/mutate/zig-mutate, .c8rc.json, stryker.conf.json, pixi.toml, cosmic-ray.toml, tests/{functional,regression,e2e,differential}/ scaffolding, .github/workflows/test-coverage.yml) + the spec/master-plan docs. Resolve every conflict by KEEPING the tooling AND the post-R6 source state (R6 wins on src, the branch wins on the new tooling files). After rebase: zig build -Dtool=caveman + zig build test exit 0; the 6 tooling artifacts exist; biome on PATH. Force-push the rebased branch. STOP before merge — surface the clean mergeable state for approval.",
	blockers: [],
};

const T_pz_prs: Thread = {
	id: "pz.prs",
	repo: "pz",
	title: "Review + merge pz PR #19 (coverage plan) + #20 (provider adapters)",
	risk: "review",
	dependsOn: [],
	owns: [
		"pz:branch:pz/test-coverage-plan",
		"pz:branch:pz/runtime-policy-cli-adapters",
	],
	inputs: ["pz:main"],
	outputs: ["pz PR #19 merged → main", "pz PR #20 merged → main"],
	uses: ["gh api", "zig build/test", "ziglint"],
	subagents: ["pz-reviewer", "ci-verifier"],
	gates: [
		...zigGate("pz"),
		{
			name: "merge 19",
			cmd: "gh api repos/EugOT/pz/pulls/19/merge -X PUT -f merge_method=merge",
			requiresApproval: true,
		},
		{
			name: "merge 20",
			cmd: "gh api repos/EugOT/pz/pulls/20/merge -X PUT -f merge_method=merge",
			requiresApproval: true,
		},
	],
	accept: [
		"Both PRs reviewed (read the diffs, verify findings against current code).",
		"#20 (provider command adapters) — security-relevant; confirm the policy gate is correct + tested.",
		"zig build + zig build test green on each branch; ziglint introduces no new findings; merged → main.",
	],
	prompt:
		"EugOT/pz has 2 open PRs to main, both mergeable=clean: #19 (docs: TEST-COVERAGE-PLAN — 100% meaningful coverage backlog) and #20 (fix(runtime): require approved provider command adapters — security). For EACH: checkout the branch, read the FULL diff, verify the change does what the title claims against current src/, run cd . && zig build + zig build test (exit 0), run ziglint src/**/*.zig and confirm no NEW findings. #20 is security-sensitive (provider command adapter allow-listing) — confirm the policy.eval gate path is correct and has a test. Report each PR's verdict + gate results. STOP before merge for approval.",
	blockers: [],
};

const T_ponytail_upstream_analysis: Thread = {
	id: "ponytail.upstream.analysis",
	repo: "ponytail",
	title: "Classify the 39 upstream DietrichGebert commits (read-only)",
	risk: "safe",
	dependsOn: [],
	owns: [], // read-only
	inputs: ["ponytail:upstream/main", "ponytail:origin/main"],
	outputs: ["ponytail/docs/upstream-sync-2026-06-27.md (classification table)"],
	uses: ["git log/show/range-diff", "gh api"],
	subagents: ["commit-classifier"],
	gates: [
		{
			name: "classification doc exists",
			cmd: "test -f docs/upstream-sync-2026-06-27.md",
			requiresApproval: false,
		},
	],
	accept: [
		"Every one of the 39 commits classified: ABSORB (runtime/fix we want) | ADAPT (touches retired JS — port intent to Zig) | SKIP (npm-packaging/i18n/docs/sponsor irrelevant to our pure-Zig fork) | CONFLICT (touches files we rewrote).",
		"For ABSORB/ADAPT: the exact cherry-pick or semantic-port note + which Zig file absorbs it.",
	],
	prompt:
		"EugOT/ponytail/main (feb5f80) is 39 commits BEHIND upstream DietrichGebert/main and we want the valuable colleague work WITHOUT submitting anything upstream. The fork is pure-Zig for native paths (we retired hooks/*.js → Zig; pi-extension/.opencode stay JS). For each of the 39 commits (git log origin/main..upstream/main), classify: ABSORB (runtime feature/fix we want e.g. #254 SubagentStart ruleset inject, #275/#279 pi status-bar, #265 PowerShell hook parse, #253 comprehension-first guard, benchmark fixes #315/#274/#232), ADAPT (touches JS we already ported → port the INTENT into the Zig equivalent, name the file), SKIP (npm-packaging #197/#280/#282, i18n READMEs, sponsor/banner/trendshift docs, ClawHub publish), CONFLICT (touches a file our rewrite changed — note the collision). Output docs/upstream-sync-2026-06-27.md with a table: commit | subject | class | action | target-zig-file. READ-ONLY: do not merge/cherry-pick/modify anything.",
	blockers: [
		"upstream remote added locally (git remote add upstream https://github.com/DietrichGebert/ponytail.git && git fetch upstream) — DONE this session.",
	],
};

const T_ponytail_surface_audit: Thread = {
	id: "ponytail.surface.audit",
	repo: "ponytail",
	title: "Audit non-Zig surface — per-harness Zig-rewrite plan (read-only)",
	risk: "safe",
	dependsOn: [],
	owns: [],
	inputs: ["ponytail:origin/main src tree"],
	outputs: ["ponytail/docs/zig-rewrite-plan-2026-06-27.md"],
	uses: ["git ls-tree", "ast-grep", "zigdoc"],
	subagents: ["dependency-mapper", "harness-mapper"],
	gates: [
		{
			name: "plan doc exists",
			cmd: "test -f docs/zig-rewrite-plan-2026-06-27.md",
			requiresApproval: false,
		},
	],
	accept: [
		"Every non-Zig file (JS 2660 / Py 1473) classified: RUNTIME-RETIRE (Zig replacement exists/feasible) | IRREDUCIBLE (harness mandates JS: pi-extension/index.js, .opencode/ponytail.mjs) | TOOLING (benchmarks/*, scripts/* — Zig-rewrite candidate, lower prio) | TEST (follows its target).",
		"Import-graph proof for each RETIRE candidate: no surviving JS/ESM consumer (the trap that broke earlier ponytail retirement — pi-extension chain config→fs-safe→instructions→instructions-bin).",
		"Per-harness mapping: which Zig binary/skill serves Claude Code, Codex, Copilot, opencode, pi, OpenClaw, pz.",
	],
	prompt:
		"ponytail/main: JS 2660 LOC, Py 1473 LOC, Zig 2377 LOC. The user wants the non-Zig surface rewritten in Zig per-harness where each harness needs it, keeping only TRULY irreducible shims. Build docs/zig-rewrite-plan-2026-06-27.md. STEP 1 import-graph: for each hooks/*.js + pi-extension/*.js + .opencode/*.mjs, list every require/import edge (use ast-grep) and which harness loads it — a file is IRREDUCIBLE iff a JS-mandated harness (pi ESM, opencode ESM) imports it and the chain can't be served by a Zig binary. CRITICAL: the prior retirement broke because pi-extension/index.js → ponytail-config.js → ponytail-fs-safe.js → ponytail-instructions.js → ponytail-instructions-bin.js is one chain; re-verify the true minimal irreducible set. STEP 2 classify benchmarks/agentic/*.py (1473) + benchmarks/*.js as TOOLING Zig-candidates with effort estimate. STEP 3 per-harness table: harness → how ponytail reaches it today (binary/skill/shim) → target pure-Zig form. READ-ONLY.",
	blockers: [],
};

const WAVE1: Wave = {
	id: "wave1",
	title: "Independent merges + read-only analysis",
	threads: [
		T_caveman_pr13,
		T_pz_prs,
		T_ponytail_upstream_analysis,
		T_ponytail_surface_audit,
	],
};

// ─────────────────────────────────────────────────────────────────────────────
// WAVE 2 — ponytail mutations (gated on Wave-1 analysis; sequential within repo)
// ─────────────────────────────────────────────────────────────────────────────

const T_ponytail_absorb_upstream: Thread = {
	id: "ponytail.absorb.upstream",
	repo: "ponytail",
	title: "Absorb/adapt the ABSORB+ADAPT upstream commits into Zig",
	risk: "review",
	dependsOn: ["ponytail.upstream.analysis", "ponytail.surface.audit"],
	owns: [
		"ponytail:branch:zig/upstream-absorb",
		"ponytail:zig/src",
		"ponytail:hooks",
		"ponytail:pi-extension",
	],
	inputs: ["ponytail/docs/upstream-sync-2026-06-27.md"],
	outputs: ["ponytail branch zig/upstream-absorb", "ponytail PR → dev"],
	uses: ["git cherry-pick", "zig build/test", "ziglint", "zigdoc"],
	subagents: ["porter", "test-author", "ci-verifier"],
	gates: [
		...zigGate("ponytail"),
		{
			name: "ziglint clean",
			cmd: `${ZIGLINT} zig/src/*.zig`,
			requiresApproval: false,
		},
	],
	accept: [
		"Each ABSORB commit cherry-picked or its intent ported; each ADAPT commit's behavior implemented in the named Zig file with a test.",
		"SubagentStart ruleset injection (#254) reaches the Zig instruction path; PowerShell hook-parse fix (#265) reflected in the .ps1 shims; pi status-bar (#275) handled (pi-extension is JS — keep or note).",
		"zig build+test green; CVE-2026-25536 NOT reintroduced (no @modelcontextprotocol/sdk).",
	],
	prompt:
		"Using docs/upstream-sync-2026-06-27.md (from ponytail.upstream.analysis), on a new branch zig/upstream-absorb off dev: for each ABSORB commit cherry-pick it (resolve conflicts keeping our Zig); for each ADAPT commit port the INTENT into the target Zig file named in the doc + add a Zig test. Verify zig build + zig build test exit 0 after each, ziglint clean of new findings, and CVE-2026-25536 is NOT reintroduced (grep: no @modelcontextprotocol/sdk anywhere). Use zigdoc for any std API. STAGE only; open the PR for the owning session to gate.",
	blockers: [],
};

const T_ponytail_zig_rewrite: Thread = {
	id: "ponytail.zig.rewrite",
	repo: "ponytail",
	title: "Per-harness JS/Py→Zig rewrite (RUNTIME-RETIRE set) + pz-extension",
	risk: "review",
	dependsOn: ["ponytail.surface.audit", "ponytail.absorb.upstream"],
	owns: [
		"ponytail:branch:zig/harness-rewrite",
		"ponytail:zig/src",
		"ponytail:hooks",
		"ponytail:pz-extension",
	],
	inputs: ["ponytail/docs/zig-rewrite-plan-2026-06-27.md"],
	outputs: [
		"ponytail branch zig/harness-rewrite",
		"ponytail PR → dev",
		"ponytail/.pz/skills emitter",
	],
	uses: ["zig build/test", "ziglint", "zigdoc", "ast-grep"],
	subagents: ["zig-porter", "import-verifier", "test-author"],
	gates: [
		...zigGate("ponytail"),
		{
			name: "no broken JS import",
			cmd: "bash tools/verify-js-imports.sh",
			requiresApproval: false,
		},
		{
			name: "ziglint",
			cmd: `${ZIGLINT} zig/src/*.zig`,
			requiresApproval: false,
		},
	],
	accept: [
		"Only the RUNTIME-RETIRE set deleted; every surviving JS/ESM import resolves (import-graph proof, the prior-break guard).",
		"pz-extension: a Zig path emits ./.pz/skills/ponytail/SKILL.md + ~/.pz/skills/ponytail/ from the instructions binary (pz loads skills, not JS — cleaner than pi-extension; no JS shim).",
		"Irreducible set kept + documented; zig build+test green; sandboxed install dry-run clean.",
	],
	prompt:
		"Using docs/zig-rewrite-plan-2026-06-27.md, on branch zig/harness-rewrite off the absorb branch: delete ONLY the RUNTIME-RETIRE files; for each, re-verify (ast-grep) no surviving JS/ESM consumer BEFORE deleting (the pi-extension chain trap — restore immediately if an import breaks). Fold their logic into the named Zig file. ADD the pz-extension: pz loads ~/.pz/skills/ and ./.pz/skills/ SKILL.md (frontmatter name/description/user_invocable + body); make the Zig instructions binary emit .pz/skills/ponytail/SKILL.md with the mode-filtered ruleset (mirror how .openclaw/skills is generated, but Zig-native — no JS). Keep IRREDUCIBLE shims. Gate after EACH deletion: zig build+test exit 0 AND every relative JS import still resolves. STAGE only; PR for gating.",
	blockers: [],
};

const WAVE2: Wave = {
	id: "wave2",
	title: "ponytail mutations (gated on analysis)",
	threads: [T_ponytail_absorb_upstream, T_ponytail_zig_rewrite],
};

// ─────────────────────────────────────────────────────────────────────────────
// WAVE 3 — land + report
// ─────────────────────────────────────────────────────────────────────────────

const T_land: Thread = {
	id: "land.all",
	repo: "ponytail",
	title: "Gate-verify, PR→dev→main for ponytail; confirm caveman/pz landed",
	risk: "unsafe",
	dependsOn: [
		"caveman.pr13",
		"pz.prs",
		"ponytail.absorb.upstream",
		"ponytail.zig.rewrite",
	],
	owns: ["ponytail:dev", "ponytail:main"],
	inputs: ["all wave-2 PRs"],
	outputs: [
		"ponytail dev→main PR merged",
		"report at https://report.cordillera.home/r/<rugs>",
	],
	uses: ["gh api pulls/merge", "git", "curl report_host"],
	subagents: ["final-verifier", "reporter"],
	gates: [
		...zigGate("ponytail"),
		{
			name: "language-bar delta recorded",
			cmd: "bash tools/lang-surface.sh",
			requiresApproval: false,
		},
		{
			name: "dev→main merge",
			cmd: "gh api repos/EugOT/ponytail/pulls/<n>/merge -X PUT",
			requiresApproval: true,
		},
	],
	accept: [
		"All wave-2 ponytail PRs merged → dev (each independently gate-verified by the owning session).",
		"ponytail dev→main PR opened, CI/review clean, merged (APPROVAL GATE — production install source).",
		"Interactive HTML report published to report.cordillera.home/r/<rugs> with findings + validation + blockers.",
	],
	prompt:
		"Owning-session-only (not a delegated agent): independently re-run every gate on each wave-2 ponytail PR (zig build/test, sandboxed install dry-run, import-resolution, no-CVE), merge each → dev, then open ponytail dev→main and STOP for explicit user approval before the production merge. Record the JS/Py/Zig language-surface delta. Publish the interactive HTML report.",
	blockers: [
		"report.cordillera.home reachability + slug <rugs> — verify https://report.cordillera.home/r/<rugs> serves before claiming published.",
	],
};

const WAVE3: Wave = { id: "wave3", title: "Land + report", threads: [T_land] };

// ─────────────────────────────────────────────────────────────────────────────
// Program + ownership-overlap assertion (compile-time-ish guard)
// ─────────────────────────────────────────────────────────────────────────────

export const PROGRAM: Program = {
	name: "cpz-rewrite",
	model: "opus",
	waves: [WAVE1, WAVE2, WAVE3],
	invariants: INVARIANTS,
};

/** True if `a` is reachable from `b` (or vice-versa) through the dependsOn DAG —
 *  i.e. the two threads are dependency-ordered and can NEVER run concurrently, so
 *  shared ownership is safe (a sequential hand-off, not a parallel edit race). */
function dependencyOrdered(
	a: Thread,
	b: Thread,
	all: readonly Thread[],
): boolean {
	const byId = new Map(all.map((t) => [t.id, t]));
	const reaches = (from: Thread, to: string): boolean => {
		const stack = [...from.dependsOn];
		const seen = new Set<string>();
		while (stack.length) {
			const id = stack.pop() as string;
			if (id === to) return true;
			if (seen.has(id)) continue;
			seen.add(id);
			const dep = byId.get(id);
			if (dep) stack.push(...dep.dependsOn);
		}
		return false;
	};
	return reaches(a, b.id) || reaches(b, a.id);
}

/** Two threads that COULD run concurrently must not own overlapping paths.
 *  Threads linked by dependsOn run in sequence, so shared ownership is a safe
 *  hand-off. Checks across the whole program (waves are scheduling hints, not
 *  the ownership boundary). */
export function assertNoOverlap(program: Program): void {
	const all = program.waves.flatMap((w) => w.threads);
	for (const [i, a] of all.entries()) {
		for (const b of all.slice(i + 1)) {
			if (dependencyOrdered(a, b, all)) continue; // sequential hand-off — safe
			const shared = a.owns.filter((p) => b.owns.includes(p));
			if (shared.length) {
				throw new Error(
					`ownership conflict: ${a.id} and ${b.id} can run concurrently and both own ${shared.join(", ")}`,
				);
			}
		}
	}
}

assertNoOverlap(PROGRAM);

export default PROGRAM;
