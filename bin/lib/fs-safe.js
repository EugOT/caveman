// Small filesystem helpers for installer writes that must not follow an
// existing symlink target.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function readIfExists(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; }
}

function lstatIfExists(p) {
  try { return fs.lstatSync(p); }
  catch (e) {
    if (e && e.code === 'ENOENT') return null;
    throw e;
  }
}

function unsafeTargetReason(p, wantDir = false) {
  const stat = lstatIfExists(p);
  if (!stat) return null;
  if (stat.isSymbolicLink()) return 'refusing to write through symlink';
  if (wantDir && !stat.isDirectory()) return 'target is not a directory';
  if (!wantDir && stat.isDirectory()) return 'target is a directory';
  if (!wantDir && !stat.isFile()) return 'target is not a regular file';
  return null;
}

function unsafeParentReason(p, rootDir) {
  const parent = path.resolve(path.dirname(p));
  const root = rootDir ? path.resolve(rootDir) : path.parse(parent).root;
  const rootStat = lstatIfExists(root);
  if (rootStat) {
    if (rootStat.isSymbolicLink()) return `refusing to write through symlinked parent: ${root}`;
    if (!rootStat.isDirectory()) return `parent is not a directory: ${root}`;
  }
  const relative = path.relative(root, parent);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    return `target is outside safe root: ${root}`;
  }
  if (!relative) return null;

  let current = root;
  for (const part of relative.split(path.sep)) {
    if (!part) continue;
    current = path.join(current, part);
    const stat = lstatIfExists(current);
    if (!stat) return null;
    if (stat.isSymbolicLink()) return `refusing to write through symlinked parent: ${current}`;
    if (!stat.isDirectory()) return `parent is not a directory: ${current}`;
  }
  return null;
}

function unsafeWriteReason(p, rootDir) {
  return unsafeTargetReason(p) || unsafeParentReason(p, rootDir);
}

function unsafeReasonCode(reason) {
  if (reason.includes('symlink')) return 'EISLINK';
  if (reason.includes('not a directory')) return 'ENOTDIR';
  if (reason.includes('directory')) return 'EISDIR';
  return 'EINVAL';
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

  const suffix = `${process.pid}.${Date.now()}.${crypto.randomBytes(6).toString('hex')}`;
  const tmp = path.join(path.dirname(target), `.${path.basename(target)}.${suffix}.tmp`);
  try {
    fs.writeFileSync(tmp, content, { mode: 0o644, flag: 'wx' });
    fs.renameSync(tmp, target);
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) {}
  }
}

module.exports = {
  readIfExists,
  lstatIfExists,
  unsafeParentReason,
  unsafeReasonCode,
  unsafeTargetReason,
  unsafeWriteReason,
  writeFileSafe,
};
