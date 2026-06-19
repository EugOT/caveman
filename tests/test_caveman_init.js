#!/usr/bin/env node
// Tests for src/tools/caveman-init.js — fixture-based.
// Run: node tests/test_caveman_init.js

const fs = require("fs");
const path = require("path");
const os = require("os");
const assert = require("assert");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const INIT = path.join(ROOT, "src", "tools", "caveman-init.js");

let passed = 0;
let failed = 0;
let skipped = 0;
const SYMLINK_SETUP_SKIP_CODES = new Set([
	"EACCES",
	"ENOSYS",
	"ENOTSUP",
	"EPERM",
]);

// Point OPENCLAW_WORKSPACE at a nonexistent dir inside the fixture so the
// openclaw target reports skipped-workspace-missing instead of writing to
// the developer's real ~/.openclaw/workspace.
function runInit(tmp, ...args) {
	return execFileSync(process.execPath, [INIT, tmp, ...args], {
		encoding: "utf8",
		env: {
			...process.env,
			OPENCLAW_WORKSPACE: path.join(tmp, "no-openclaw"),
			NULLCLAW_WORKSPACE: path.join(tmp, "no-nullclaw"),
		},
	});
}

function isSymlinkSetupUnsupported(e) {
	return e && SYMLINK_SETUP_SKIP_CODES.has(e.code);
}

function test(name, fn) {
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "caveman-init-test-"));
	try {
		const result = fn(tmp);
		if (result && result.skip) {
			skipped++;
			console.log(`  - ${name} (skipped: ${result.skip})`);
			return;
		}
		passed++;
		console.log(`  ✓ ${name}`);
	} catch (e) {
		failed++;
		console.error(`  ✗ ${name}\n    ${e.message}`);
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

console.log("caveman-init tests\n");

test("greenfield: creates all rule files with proper frontmatter", (tmp) => {
	runInit(tmp);
	const cursor = fs.readFileSync(
		path.join(tmp, ".cursor/rules/caveman.mdc"),
		"utf8",
	);
	assert.match(cursor, /alwaysApply: true/);
	assert.match(cursor, /Respond terse like smart caveman/);
	const windsurf = fs.readFileSync(
		path.join(tmp, ".windsurf/rules/caveman.md"),
		"utf8",
	);
	assert.match(windsurf, /trigger: always_on/);
	const cline = fs.readFileSync(
		path.join(tmp, ".clinerules/caveman.md"),
		"utf8",
	);
	assert.match(cline, /^Respond terse/);
	const copilot = fs.readFileSync(
		path.join(tmp, ".github/copilot-instructions.md"),
		"utf8",
	);
	assert.match(copilot, /Respond terse/);
	const agents = fs.readFileSync(path.join(tmp, "AGENTS.md"), "utf8");
	assert.match(agents, /Respond terse/);
	const opencode = fs.readFileSync(
		path.join(tmp, ".opencode/AGENTS.md"),
		"utf8",
	);
	assert.match(opencode, /Respond terse/);
});

test("idempotent: re-running on a clean install skips all", (tmp) => {
	runInit(tmp);
	const out = runInit(tmp);
	// 6 repo rule files skipped-already-installed + openclaw skipped (no workspace)
	assert.match(out, /7 skipped/);
	assert.doesNotMatch(out, /[1-9]\d* added/);
});

test("append mode: existing AGENTS.md gets caveman appended (not replaced)", (tmp) => {
	fs.writeFileSync(
		path.join(tmp, "AGENTS.md"),
		"# My project\n\nDo not delete me.\n",
	);
	runInit(tmp);
	const agents = fs.readFileSync(path.join(tmp, "AGENTS.md"), "utf8");
	assert.match(agents, /Do not delete me/);
	assert.match(agents, /Respond terse like smart caveman/);
});

test("skip mode: existing .cursor rule is not overwritten without --force", (tmp) => {
	const dir = path.join(tmp, ".cursor/rules");
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(
		path.join(dir, "caveman.mdc"),
		"# original\nDo not delete me.\n",
	);
	const out = runInit(tmp);
	assert.match(out, /\? .*\.cursor\/rules\/caveman\.mdc/);
	const after = fs.readFileSync(path.join(dir, "caveman.mdc"), "utf8");
	assert.strictEqual(after, "# original\nDo not delete me.\n");
});

test("--force overwrites existing rule files", (tmp) => {
	const dir = path.join(tmp, ".cursor/rules");
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, "caveman.mdc"), "# original\n");
	runInit(tmp, "--force");
	const after = fs.readFileSync(path.join(dir, "caveman.mdc"), "utf8");
	assert.match(after, /alwaysApply: true/);
	assert.match(after, /Respond terse/);
});

test("--dry-run: announces but writes nothing", (tmp) => {
	const out = runInit(tmp, "--dry-run");
	assert.match(out, /\(dry run\)/);
	assert.match(out, /6 added/);
	assert.ok(!fs.existsSync(path.join(tmp, ".cursor")));
	assert.ok(!fs.existsSync(path.join(tmp, ".windsurf")));
	assert.ok(!fs.existsSync(path.join(tmp, ".clinerules")));
	assert.ok(!fs.existsSync(path.join(tmp, ".github/copilot-instructions.md")));
	assert.ok(!fs.existsSync(path.join(tmp, ".opencode")));
	assert.ok(!fs.existsSync(path.join(tmp, "AGENTS.md")));
});

test("--only filters to one target", (tmp) => {
	const out = runInit(tmp, "--only", "cline");
	assert.match(out, /1 added/);
	assert.ok(fs.existsSync(path.join(tmp, ".clinerules/caveman.md")));
	assert.ok(!fs.existsSync(path.join(tmp, ".cursor")));
});

test("--only codex-app writes universal contract plus Codex project skill", (tmp) => {
	const out = runInit(tmp, "--only", "codex-app");
	assert.match(out, /3 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	const skill = fs.readFileSync(
		path.join(tmp, ".codex/skills/caveman/SKILL.md"),
		"utf8",
	);
	assert.match(skill, /^---\nname: caveman/m);
	assert.match(skill, /Respond terse like smart caveman/);
	assert.ok(!fs.existsSync(path.join(tmp, ".cursor")));
});

test("--only pi writes universal contract plus Pi project skill", (tmp) => {
	const out = runInit(tmp, "--only", "pi");
	assert.match(out, /3 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".pi/skills/caveman/SKILL.md")));
});

test("--only pz writes universal contract plus pz project skill", (tmp) => {
	const out = runInit(tmp, "--only", "pz");
	assert.match(out, /3 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".pz/skills/caveman/SKILL.md")));
});

test("--only walcode writes universal, claw, and shared Codex-style skill files", (tmp) => {
	const out = runInit(tmp, "--only", "walcode");
	assert.match(out, /4 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	const instructions = fs.readFileSync(
		path.join(tmp, ".claw/instructions.md"),
		"utf8",
	);
	assert.match(instructions, /Respond terse like smart caveman/);
	assert.ok(fs.existsSync(path.join(tmp, ".codex/skills/caveman/SKILL.md")));
});

test("--only claude-desktop writes AGENTS.md, CLAUDE.md import, and Claude project skill", (tmp) => {
	const out = runInit(tmp, "--only", "claude-desktop");
	assert.match(out, /4 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	assert.match(
		fs.readFileSync(path.join(tmp, "CLAUDE.md"), "utf8"),
		/^@AGENTS\.md/m,
	);
	assert.ok(fs.existsSync(path.join(tmp, ".claude/skills/caveman/SKILL.md")));
});

test("--only perplexity writes universal repo contract without native-provider claim", (tmp) => {
	const out = runInit(tmp, "--only", "perplexity");
	assert.match(out, /2 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
	assert.ok(!fs.existsSync(path.join(tmp, ".perplexity")));
});

test("--only warpPreview writes universal AGENTS.md and project skill", (tmp) => {
	const out = runInit(tmp, "--only", "warpPreview");
	assert.match(out, /2 added/);
	assert.ok(fs.existsSync(path.join(tmp, "AGENTS.md")));
	assert.ok(fs.existsSync(path.join(tmp, ".agents/skills/caveman/SKILL.md")));
});

test("CLAUDE.md import target is idempotent when @AGENTS.md already exists", (tmp) => {
	fs.writeFileSync(
		path.join(tmp, "CLAUDE.md"),
		"@AGENTS.md\n\n## Claude-only\nKeep this.\n",
	);
	const out = runInit(tmp, "--only", "claude-code");
	assert.match(out, /skipped-already-installed/);
	const claude = fs.readFileSync(path.join(tmp, "CLAUDE.md"), "utf8");
	assert.equal((claude.match(/@AGENTS\.md/g) || []).length, 1);
});

test("CLAUDE.md import target appends when legacy caveman text lacks @AGENTS.md", (tmp) => {
	fs.writeFileSync(
		path.join(tmp, "CLAUDE.md"),
		"## Legacy\nRespond terse like smart caveman. Keep this.\n",
	);
	const out = runInit(tmp, "--only", "claude-code");
	assert.match(out, /CLAUDE\.md \(appended\)/);
	const claude = fs.readFileSync(path.join(tmp, "CLAUDE.md"), "utf8");
	assert.match(claude, /Respond terse like smart caveman/);
	assert.equal((claude.match(/@AGENTS\.md/g) || []).length, 1);
});

test("safety: refuses to write through existing symlink targets", (tmp) => {
	const outside = path.join(
		tmp,
		"..",
		`caveman-init-outside-${process.pid}.md`,
	);
	fs.writeFileSync(outside, "outside stays unchanged\n");
	try {
		fs.symlinkSync(outside, path.join(tmp, "AGENTS.md"));
	} catch (e) {
		fs.rmSync(outside, { force: true });
		if (isSymlinkSetupUnsupported(e))
			return { skip: `symlink setup unsupported: ${e.code}` };
		throw e;
	}
	try {
		const out = runInit(tmp, "--only", "antigravity-app");
		assert.match(out, /skipped-symlink/);
		assert.strictEqual(
			fs.readFileSync(outside, "utf8"),
			"outside stays unchanged\n",
		);
	} finally {
		fs.rmSync(outside, { force: true });
	}
});

test("safety: refuses to write through symlinked parent directories", (tmp) => {
	const outsideDir = path.join(
		tmp,
		"..",
		`caveman-init-outside-dir-${process.pid}`,
	);
	fs.mkdirSync(outsideDir);
	try {
		fs.symlinkSync(outsideDir, path.join(tmp, ".codex"));
	} catch (e) {
		fs.rmSync(outsideDir, { recursive: true, force: true });
		if (isSymlinkSetupUnsupported(e))
			return { skip: `symlink setup unsupported: ${e.code}` };
		throw e;
	}
	try {
		const out = runInit(tmp, "--only", "codex-app");
		assert.match(out, /skipped-unsafe-parent/);
		assert.ok(
			fs.existsSync(path.join(tmp, "AGENTS.md")),
			"AGENTS.md should still be written",
		);
		assert.equal(
			fs.existsSync(path.join(outsideDir, "skills", "caveman", "SKILL.md")),
			false,
			"skill should not be written through parent symlink",
		);
	} finally {
		fs.rmSync(outsideDir, { recursive: true, force: true });
	}
});

test("detects sentinel and skips files that already have caveman content", (tmp) => {
	// Hand-write a file that already contains the rule (simulating prior install).
	const dir = path.join(tmp, ".clinerules");
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(
		path.join(dir, "caveman.md"),
		"# Existing\n\nRespond terse like smart caveman. Hello.\n",
	);
	const out = runInit(tmp, "--only", "cline");
	assert.match(out, /skipped-already-installed/);
});

console.log(`\n${passed} passed, ${skipped} skipped, ${failed} failed`);
process.exit(failed ? 1 : 0);
