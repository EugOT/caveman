// caveman -> NullClaw install / uninstall helper.
//
// NullClaw loads user skills from $NULLCLAW_WORKSPACE/skills/<name>/,
// $NULLCLAW_HOME/workspace/skills/<name>/, or by default
// ~/.nullclaw/workspace/skills/<name>/. A SKILL.md YAML
// frontmatter field `always: true` makes the full instructions part of the
// system prompt, which is the closest NullClaw-native match for caveman's
// always-on behavior.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const { readIfExists, unsafeParentReason, unsafeTargetReason, unsafeWriteReason, writeFileSafe } = require('./fs-safe');
const OPENCLAW = require('./openclaw');

const SKILL_NAME = 'caveman';

function resolveWorkspace(env = process.env) {
  if (env.NULLCLAW_WORKSPACE) return path.resolve(env.NULLCLAW_WORKSPACE);
  const home = env.NULLCLAW_HOME ? path.resolve(env.NULLCLAW_HOME) : path.join(os.homedir(), '.nullclaw');
  return path.join(home, 'workspace');
}

function loadSkillBody(repoRoot) {
  if (!repoRoot) return null;
  return readIfExists(path.join(repoRoot, 'skills', SKILL_NAME, 'SKILL.md'));
}

function installNullclaw({ workspace, repoRoot, dryRun = false, force = false, log = noopLog() } = {}) {
  const ws = workspace || resolveWorkspace();
  const skillBody = loadSkillBody(repoRoot);
  if (!skillBody) {
    log.warn('  nullclaw install requires the caveman repo on disk (skills/caveman/SKILL.md missing).');
    log.note('  Re-run from a clone or via `npx -y github:JuliusBrussee/caveman -- --only nullclaw`.');
    return { ok: false, reason: 'repo not available' };
  }
  const unsafeWorkspace = unsafeTargetReason(ws, true) || unsafeParentReason(path.join(ws, '.caveman-workspace-probe'), path.dirname(ws));
  if (unsafeWorkspace) {
    log.warn(`  nullclaw unsafe target at ${ws}: ${unsafeWorkspace}.`);
    return { ok: false, reason: 'unsafe target' };
  }

  if (!fs.existsSync(ws)) {
    if (!force) {
      log.warn(`  nullclaw workspace not found at ${ws}.`);
      log.note('  Either run `nullclaw onboard` and re-run, set NULLCLAW_WORKSPACE, or pass --force to mkdir.');
      return { ok: false, reason: 'workspace missing' };
    }
    if (!dryRun) fs.mkdirSync(ws, { recursive: true });
  }

  const skillDir = path.join(ws, 'skills', SKILL_NAME);
  const skillFile = path.join(skillDir, 'SKILL.md');
  const merged = OPENCLAW.mergeOpenclawFrontmatter(skillBody);
  const unsafeDir = unsafeTargetReason(skillDir, true);
  const unsafeFile = unsafeWriteReason(skillFile, ws);
  const unsafe = unsafeDir || unsafeFile;
  if (unsafe) {
    log.warn(`  nullclaw unsafe target at ${unsafeDir ? skillDir : skillFile}: ${unsafe}.`);
    return { ok: false, reason: 'unsafe target' };
  }

  if (dryRun) {
    log.note(`  would write ${skillFile} (with version/always frontmatter)`);
    return { ok: true, dryRun: true };
  }

  writeFileSafe(skillFile, merged, ws);
  log.write(`  installed: ${skillFile}\n`);
  return { ok: true };
}

function uninstallNullclaw({ workspace, dryRun = false, log = noopLog() } = {}) {
  const ws = workspace || resolveWorkspace();
  const skillDir = path.join(ws, 'skills', SKILL_NAME);
  if (!fs.existsSync(skillDir)) return { ok: true, touched: false };

  if (dryRun) {
    log.note(`  would remove ${skillDir}/`);
  } else {
    try { fs.rmSync(skillDir, { recursive: true, force: true }); } catch (_) {}
    log.note(`  removed ${skillDir}`);
  }
  return { ok: true, touched: true };
}

function noopLog() {
  return {
    write: (_) => {},
    note: (_) => {},
    warn: (_) => {},
  };
}

module.exports = {
  installNullclaw,
  uninstallNullclaw,
  resolveWorkspace,
  unsafeParentReason,
  unsafeTargetReason,
  unsafeWriteReason,
  SKILL_NAME,
};
