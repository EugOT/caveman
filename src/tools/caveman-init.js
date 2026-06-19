#!/usr/bin/env node
// caveman init — drop the always-on caveman activation rule into a target
// repo for every IDE agent we support. Idempotent. Safe to re-run.
//
// Usage:
//   node src/tools/caveman-init.js [target-dir] [--dry-run] [--force] [--only <agent>]
//   curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/src/tools/caveman-init.js | node - [args]
//
// Without args, runs in cwd. Generates the default rule files for Cursor,
// Windsurf, Cline, Copilot, opencode, and AGENTS.md. Explicit Claude-compatible
// aliases may also add a CLAUDE.md import bridge. Does not compress existing
// memory files — that's the job of `/caveman:compress`.

const fs = require("fs");
const path = require("path");

// Embedded so the tool works standalone (npx-style) without the src/rules/ dir.
// Mirrors src/rules/caveman-activate.md verbatim — keep these in sync.
const RULE_BODY = `Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
`;

const SENTINEL = "Respond terse like smart caveman";
const UNIVERSAL_AGENT_ALIASES = [
	"agents",
	"antigravity",
	"antigravity-app",
	"antigravity-cli",
	"claude",
	"claude-code",
	"claude-desktop",
	"claw",
	"codex",
	"codex-app",
	"codex-cli",
	"goclaw",
	"hermes",
	"nullclaw",
	"opencode",
	"openclaw",
	"perplexity",
	"pi",
	"pz",
	"walcode",
	"walkode",
	"warp",
	"warp-preview",
	"warppreview",
	"zeroclaw",
];
const CLAUDE_COMPAT_ALIASES = ["claude", "claude-code", "claude-desktop"];
const CODEX_STYLE_SKILL_ALIASES = [
	"codex",
	"codex-app",
	"codex-cli",
	"claw",
	"goclaw",
	"walcode",
	"walkode",
	"zeroclaw",
];

// OpenClaw is a global workspace tool (not per-repo) and needs two write
// targets — a skill folder + a SOUL.md bootstrap block. The shared helper
// lives at bin/lib/openclaw.js; we require it lazily so caveman-init.js
// keeps working when run standalone (curl|node) without the helper on disk.
function loadOpenclawHelper() {
	try {
		return require(
			path.join(__dirname, "..", "..", "bin", "lib", "openclaw.js"),
		);
	} catch (_) {
		return null;
	}
}

function loadNullclawHelper() {
	try {
		return require(
			path.join(__dirname, "..", "..", "bin", "lib", "nullclaw.js"),
		);
	} catch (_) {
		return null;
	}
}

const AGENTS = [
	{
		id: "cursor",
		file: ".cursor/rules/caveman.mdc",
		frontmatter:
			'---\ndescription: "Caveman mode — terse communication, ~75% fewer tokens, full technical accuracy"\nalwaysApply: true\n---\n\n',
		mode: "replace",
	},
	{
		id: "windsurf",
		file: ".windsurf/rules/caveman.md",
		frontmatter: "---\ntrigger: always_on\n---\n\n",
		mode: "replace",
	},
	{
		id: "cline",
		file: ".clinerules/caveman.md",
		frontmatter: "",
		mode: "replace",
	},
	{
		id: "copilot",
		file: ".github/copilot-instructions.md",
		frontmatter: "",
		mode: "append",
	},
	{
		id: "opencode",
		file: ".opencode/AGENTS.md",
		frontmatter: "",
		mode: "append",
	},
	{
		id: "agents",
		file: "AGENTS.md",
		frontmatter: "",
		mode: "append",
		aliases: UNIVERSAL_AGENT_ALIASES,
	},
	// Explicit-only targets. They are omitted from default `caveman-init` to
	// keep the common path small, but `--only <harness>` installs the repo-local
	// files those harnesses actually read.
	{
		id: "agents-skill",
		file: ".agents/skills/caveman/SKILL.md",
		mode: "skill",
		default: false,
		aliases: UNIVERSAL_AGENT_ALIASES,
	},
	{
		id: "claude-import",
		file: "CLAUDE.md",
		mode: "import-agents",
		default: false,
		aliases: CLAUDE_COMPAT_ALIASES,
	},
	{
		id: "codex-skill",
		file: ".codex/skills/caveman/SKILL.md",
		mode: "skill",
		default: false,
		aliases: CODEX_STYLE_SKILL_ALIASES,
	},
	{
		id: "claude-skill",
		file: ".claude/skills/caveman/SKILL.md",
		mode: "skill",
		default: false,
		aliases: CLAUDE_COMPAT_ALIASES,
	},
	{
		id: "pi-skill",
		file: ".pi/skills/caveman/SKILL.md",
		mode: "skill",
		default: false,
		aliases: ["pi"],
	},
	{
		id: "pz-skill",
		file: ".pz/skills/caveman/SKILL.md",
		mode: "skill",
		default: false,
		aliases: ["pz"],
	},
	{
		id: "claw",
		file: ".claw/instructions.md",
		frontmatter: "",
		mode: "append",
		default: false,
		aliases: ["claw", "goclaw", "walcode", "walkode", "zeroclaw"],
	},
	// OpenClaw — global workspace install, not per-repo. The `installer`
	// callback escape hatch bypasses the file/frontmatter/mode triple and
	// hands off to the shared helper. `description` is what `--help` prints.
	{
		id: "openclaw",
		description: "~/.openclaw/workspace/{skills/caveman/, SOUL.md}",
		installer: "openclaw",
	},
	{
		id: "nullclaw",
		description: "~/.nullclaw/workspace/skills/caveman/SKILL.md",
		installer: "nullclaw",
		default: false,
	},
];

function loadRuleBody() {
	// Prefer the in-repo source-of-truth when available.
	try {
		const local = path.join(__dirname, "..", "rules", "caveman-activate.md");
		if (fs.existsSync(local))
			return fs.readFileSync(local, "utf8").trimEnd() + "\n";
	} catch (e) {}
	return RULE_BODY;
}

function loadSkillBody() {
	try {
		const local = path.join(
			__dirname,
			"..",
			"..",
			"skills",
			"caveman",
			"SKILL.md",
		);
		if (fs.existsSync(local))
			return fs.readFileSync(local, "utf8").trimEnd() + "\n";
	} catch (e) {}
	return [
		"---",
		"name: caveman",
		"description: Ultra-compressed communication mode with full technical accuracy.",
		"---",
		"",
		RULE_BODY.trimEnd(),
		"",
	].join("\n");
}

function lstatIfExists(p) {
	try {
		return fs.lstatSync(p);
	} catch (e) {
		if (e && e.code === "ENOENT") return null;
		throw e;
	}
}

function unsafeTargetReason(p, wantDir = false) {
	const stat = lstatIfExists(p);
	if (!stat) return null;
	if (stat.isSymbolicLink()) return "refusing to write through symlink";
	if (wantDir && !stat.isDirectory()) return "target is not a directory";
	if (!wantDir && stat.isDirectory()) return "target is a directory";
	if (!wantDir && !stat.isFile()) return "target is not a regular file";
	return null;
}

function unsafeParentReason(p, rootDir) {
	const parent = path.resolve(path.dirname(p));
	const root = rootDir ? path.resolve(rootDir) : path.parse(parent).root;
	const rootStat = lstatIfExists(root);
	if (rootStat) {
		if (rootStat.isSymbolicLink())
			return `refusing to write through symlinked parent: ${root}`;
		if (!rootStat.isDirectory()) return `parent is not a directory: ${root}`;
	}
	const relative = path.relative(root, parent);
	if (relative.startsWith("..") || path.isAbsolute(relative)) {
		return `target is outside safe root: ${root}`;
	}
	if (!relative) return null;

	let current = root;
	for (const part of relative.split(path.sep)) {
		if (!part) continue;
		current = path.join(current, part);
		const stat = lstatIfExists(current);
		if (!stat) return null;
		if (stat.isSymbolicLink())
			return `refusing to write through symlinked parent: ${current}`;
		if (!stat.isDirectory()) return `parent is not a directory: ${current}`;
	}
	return null;
}

function unsafeWriteReason(p, rootDir) {
	return unsafeTargetReason(p) || unsafeParentReason(p, rootDir);
}

function unsafeReasonCode(reason) {
	if (reason.includes("symlink")) return "EISLINK";
	if (reason.includes("not a directory")) return "ENOTDIR";
	if (reason.includes("directory")) return "EISDIR";
	return "EINVAL";
}

function throwUnsafe(reason) {
	const err = new Error(reason);
	err.code = unsafeReasonCode(reason);
	throw err;
}

function writeFileSafe(fullPath, content, rootDir) {
	const target = path.resolve(fullPath);
	const reason = unsafeWriteReason(target, rootDir);
	if (reason) throwUnsafe(reason);

	fs.mkdirSync(path.dirname(target), { recursive: true });

	const postMkdirReason = unsafeWriteReason(target, rootDir);
	if (postMkdirReason) throwUnsafe(postMkdirReason);

	const tmp = path.join(
		path.dirname(target),
		`.${path.basename(target)}.${process.pid}.${Date.now()}.tmp`,
	);
	try {
		fs.writeFileSync(tmp, content, { mode: 0o644, flag: "wx" });
		fs.renameSync(tmp, target);
	} finally {
		try {
			fs.unlinkSync(tmp);
		} catch (_) {}
	}
}

function agentBody(agent, ruleBody) {
	if (agent.mode === "skill") return loadSkillBody();
	if (agent.mode === "import-agents") {
		return "@AGENTS.md\n\n<!-- caveman-import: Respond terse like smart caveman. Keep Claude-compatible harnesses aligned with AGENTS.md. -->\n";
	}
	return agent.frontmatter + ruleBody;
}

function processAgent(agent, targetDir, ruleBody, opts) {
	if (agent.installer === "openclaw") {
		return processOpenclaw(opts);
	}
	if (agent.installer === "nullclaw") {
		return processNullclaw(opts);
	}
	const fullPath = path.join(targetDir, agent.file);
	const stat = lstatIfExists(fullPath);
	const exists = !!stat;

	if (stat && stat.isSymbolicLink()) {
		return { status: "skipped-symlink", label: "!" };
	}
	if (stat && !stat.isFile()) {
		return { status: "skipped-non-file", label: "?" };
	}
	const unsafeParent = unsafeParentReason(fullPath, targetDir);
	if (unsafeParent) {
		return { status: "skipped-unsafe-parent", label: "!" };
	}

	if (!exists) {
		if (!opts.dryRun) {
			writeFileSafe(fullPath, agentBody(agent, ruleBody), targetDir);
		}
		return { status: "added", label: "+" };
	}

	const existing = fs.readFileSync(fullPath, "utf8");
	if (
		agent.mode === "import-agents" &&
		/(^|\n)@AGENTS\.md(\n|$)/.test(existing)
	) {
		return { status: "skipped-already-installed", label: "=" };
	}
	if (agent.mode !== "import-agents" && existing.includes(SENTINEL)) {
		return { status: "skipped-already-installed", label: "=" };
	}

	if (agent.mode === "append" || agent.mode === "import-agents") {
		if (!opts.dryRun) {
			const sep = existing.endsWith("\n\n")
				? ""
				: existing.endsWith("\n")
					? "\n"
					: "\n\n";
			writeFileSafe(
				fullPath,
				existing + sep + agentBody(agent, ruleBody),
				targetDir,
			);
		}
		return { status: "appended", label: "~" };
	}

	if (opts.force) {
		if (!opts.dryRun) {
			writeFileSafe(fullPath, agentBody(agent, ruleBody), targetDir);
		}
		return { status: "overwritten", label: "!" };
	}

	return { status: "skipped-exists", label: "?" };
}

function processOpenclaw(opts) {
	const helper = loadOpenclawHelper();
	if (!helper) {
		return {
			status: "unsupported-standalone",
			label: "x",
			detail:
				"~/.openclaw/workspace (helper unavailable in standalone curl|node mode — use `npx -y github:JuliusBrussee/caveman -- --only openclaw`)",
		};
	}
	const repoRoot = path.resolve(__dirname, "..", "..");
	const log = {
		write: (_) => {},
		note: (_) => {},
		warn: (_) => {},
	};
	const r = helper.installOpenclaw({
		workspace: process.env.OPENCLAW_WORKSPACE || undefined,
		repoRoot,
		dryRun: opts.dryRun,
		force: opts.force,
		log,
	});
	if (!r.ok) {
		return {
			status: "skipped-" + (r.reason || "failed"),
			label: "?",
			detail: helper.resolveWorkspace
				? helper.resolveWorkspace()
				: "~/.openclaw/workspace",
		};
	}
	if (r.dryRun)
		return {
			status: "would-add",
			label: "+",
			detail: helper.resolveWorkspace(),
		};
	return { status: "installed", label: "+", detail: helper.resolveWorkspace() };
}

function processNullclaw(opts) {
	const helper = loadNullclawHelper();
	if (!helper) {
		return {
			status: "unsupported-standalone",
			label: "x",
			detail:
				"~/.nullclaw/workspace (helper unavailable in standalone curl|node mode — use `npx -y github:JuliusBrussee/caveman -- --only nullclaw`)",
		};
	}
	const repoRoot = path.resolve(__dirname, "..", "..");
	const log = {
		write: (_) => {},
		note: (_) => {},
		warn: (_) => {},
	};
	const r = helper.installNullclaw({
		workspace: process.env.NULLCLAW_WORKSPACE || undefined,
		repoRoot,
		dryRun: opts.dryRun,
		force: opts.force,
		log,
	});
	if (!r.ok) {
		return {
			status: "skipped-" + (r.reason || "failed"),
			label: "?",
			detail: helper.resolveWorkspace
				? helper.resolveWorkspace()
				: "~/.nullclaw/workspace",
		};
	}
	if (r.dryRun)
		return {
			status: "would-add",
			label: "+",
			detail: helper.resolveWorkspace(),
		};
	return { status: "installed", label: "+", detail: helper.resolveWorkspace() };
}

function normalizeAgentId(id) {
	return String(id).trim().replace(/_/g, "-").toLowerCase();
}

function resolveAgents(onlyIds) {
	if (!onlyIds || onlyIds.length === 0) {
		return AGENTS.filter((agent) => agent.default !== false);
	}
	const out = [];
	const seen = new Set();
	const unknown = [];
	for (const raw of onlyIds) {
		const id = normalizeAgentId(raw);
		const matches = AGENTS.filter(
			(agent) => agent.id === id || (agent.aliases || []).includes(id),
		);
		if (matches.length === 0) {
			unknown.push(raw);
			continue;
		}
		for (const agent of matches) {
			if (seen.has(agent.id)) continue;
			seen.add(agent.id);
			out.push(agent);
		}
	}
	if (unknown.length) {
		const valid = AGENTS.flatMap((agent) => [
			agent.id,
			...(agent.aliases || []),
		]).sort();
		throw new Error(
			`unknown agent: ${unknown.join(", ")}\nvalid ids: ${[...new Set(valid)].join(", ")}`,
		);
	}
	return out;
}

function parseArgs(argv) {
	const opts = { dryRun: false, force: false, only: [], target: process.cwd() };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === "--dry-run") opts.dryRun = true;
		else if (a === "--force" || a === "-f") opts.force = true;
		else if (a === "--only") {
			const v = argv[++i];
			if (!v || v.startsWith("--"))
				throw new Error("--only requires an agent id");
			opts.only.push(v);
		} else if (a === "-h" || a === "--help") opts.help = true;
		else if (!a.startsWith("-")) opts.target = path.resolve(a);
	}
	return opts;
}

function help() {
	console.log(`caveman init — drop always-on caveman rule into a target repo

Usage: caveman-init.js [target-dir] [--dry-run] [--force] [--only <agent>]

Defaults to current working directory. Idempotent — safe to re-run.

Targets installed:
${AGENTS.map((a) => {
	const explicit = a.default === false ? " (explicit)" : "";
	const aliases =
		a.aliases && a.aliases.length ? ` aliases: ${a.aliases.join(", ")}` : "";
	return `  ${a.id.padEnd(13)} ${a.file || a.description || ""}${explicit}${aliases}`;
}).join("\n")}

Flags:
  --dry-run   show what would change, do not write
  --force     overwrite existing rule files (default: skip)
  --only <id> only install for one agent or alias (repeatable)
`);
}

function main() {
	let opts;
	try {
		opts = parseArgs(process.argv.slice(2));
	} catch (e) {
		console.error(e.message || String(e));
		process.exit(2);
	}
	if (opts.help) {
		help();
		return;
	}

	console.log(
		`🪨 caveman init — ${opts.target}${opts.dryRun ? " (dry run)" : ""}\n`,
	);

	const ruleBody = loadRuleBody();
	const counts = { added: 0, appended: 0, overwritten: 0, skipped: 0 };
	let selected;
	try {
		selected = resolveAgents(opts.only);
	} catch (e) {
		console.error(e.message || String(e));
		process.exit(2);
	}

	for (const agent of selected) {
		const result = processAgent(agent, opts.target, ruleBody, opts);
		const target = agent.file || result.detail || agent.description || agent.id;
		console.log(`  ${result.label} ${target} (${result.status})`);
		if (
			result.status === "added" ||
			result.status === "installed" ||
			result.status === "would-add"
		)
			counts.added++;
		else if (result.status === "appended") counts.appended++;
		else if (result.status === "overwritten") counts.overwritten++;
		else counts.skipped++;
	}

	console.log(
		`\n${counts.added} added, ${counts.appended} appended, ` +
			`${counts.overwritten} overwritten, ${counts.skipped} skipped`,
	);
	if (opts.dryRun) console.log("(dry run — no files were written)");
}

if (require.main === module) main();

module.exports = {
	processAgent,
	loadRuleBody,
	loadSkillBody,
	resolveAgents,
	AGENTS,
	SENTINEL,
	RULE_BODY,
};
