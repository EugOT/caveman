#!/usr/bin/env bash
# caveman — one-command hook installer for Claude Code (pure-Zig runtime).
#
# Deploys the prebuilt caveman Zig hook binaries into ~/.claude/hooks and wires
# SessionStart + UserPromptSubmit + statusline into ~/.claude/settings.json using
# the `caveman-settings` binary (no Node, no Zig toolchain required at runtime).
#
# Hooks installed (native executables, invoked directly by absolute path):
#   caveman-activate    — SessionStart      (auto-load caveman rules)
#   caveman-hook        — UserPromptSubmit  (mode tracking + per-turn reinforce)
#   caveman-statusline  — statusline badge  ([CAVEMAN] / [CAVEMAN:ULTRA] …)
#   caveman-stats       — /caveman-stats    (lifetime-savings suffix writer)
#
# Usage: bash src/hooks/install.sh
#   or:  bash <(curl -s https://raw.githubusercontent.com/JuliusBrussee/caveman/main/src/hooks/install.sh)
#   or:  bash src/hooks/install.sh --force   (re-install over existing hooks)
#   or:  bash src/hooks/install.sh --dry-run (print actions, change nothing)
set -euo pipefail

REPO="JuliusBrussee/caveman"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

err() { echo "caveman: $*" >&2; }

# Detect Windows (Git Bash / MSYS / MINGW) — not WSL (WSL reports "linux-gnu").
# The Zig binaries don't yet cross-compile to Windows; point users at install.ps1.
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*)
    err "Windows detected ($OSTYPE). The Zig hook binaries are POSIX-only for now."
    err "       Use src/hooks/install.ps1 (ships the PowerShell shim hooks),"
    err "       or 'claude plugin install' if you installed via the plugin."
    exit 1
    ;;
esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# The four hook binaries deployed into $HOOKS_DIR. caveman-settings is an
# install-time tool used only for the settings.json merge — not a hook, so it is
# NOT deployed into the hooks dir.
HOOK_BINS=(caveman-activate caveman-hook caveman-statusline caveman-stats)

# ── platform detection → release asset name ──────────────────────────────────
detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) err "unsupported OS '$os'. Windows: use install.ps1."; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *) err "unsupported arch '$arch'."; exit 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

# ── checksum helper (sha256sum on Linux, shasum on macOS) ────────────────────
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else err "no sha256sum/shasum available — cannot verify download."; exit 1; fi
}

# ── resolve a directory holding the caveman-* binaries ───────────────────────
# Strategy mirrors the root install.sh:
#   1. local clone with prebuilt binaries at zig/zig-out/bin → use as-is
#   2. local clone with `zig` on PATH → build, then use zig/zig-out/bin
#   3. otherwise → download the per-platform release archive + SHA-256 verify
# Echoes the resolved binary directory on stdout. May set BIN_TMP (caller cleans).
BIN_TMP=""
resolve_bin_dir() {
  # src/hooks/install.sh → repo root is two levels up.
  local script_dir repo_root out_bin
  script_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
  fi
  if [ -n "$script_dir" ]; then
    repo_root="$(cd "$script_dir/../.." 2>/dev/null && pwd)" || repo_root=""
    out_bin="$repo_root/zig/zig-out/bin"
    # (1) already-built clone.
    if [ -n "$repo_root" ] && _bins_present "$out_bin"; then
      echo "$out_bin"; return 0
    fi
    # (2) clone + zig toolchain → build from source.
    if [ -n "$repo_root" ] && [ -f "$repo_root/zig/build.zig" ] && command -v zig >/dev/null 2>&1; then
      err "building hook binaries from source (zig build) …"
      ( cd "$repo_root/zig" && zig build -Dtool=caveman -Doptimize=ReleaseSafe ) >&2 \
        || { err "zig build failed."; exit 1; }
      if _bins_present "$out_bin"; then echo "$out_bin"; return 0; fi
    fi
  fi
  # (3) download the release archive.
  _download_release_bin_dir
}

# True iff every hook binary AND caveman-settings exists+executable in $1.
_bins_present() {
  local d="$1" b
  [ -n "$d" ] || return 1
  for b in "${HOOK_BINS[@]}" caveman-settings; do
    [ -x "$d/$b" ] || return 1
  done
  return 0
}

_download_release_bin_dir() {
  command -v curl >/dev/null 2>&1 || { err "curl required to download release binaries."; exit 1; }
  command -v tar  >/dev/null 2>&1 || { err "tar required to unpack release binaries.";  exit 1; }
  local plat archive base
  plat="$(detect_platform)"
  archive="caveman-$plat.tar.gz"
  base="https://github.com/$REPO/releases/latest/download"
  BIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/caveman-hooks.XXXXXX")"
  err "downloading $archive …"
  curl -fsSL "$base/$archive"        -o "$BIN_TMP/$archive"        || { err "download failed ($archive). No release for $plat yet?"; exit 1; }
  curl -fsSL "$base/$archive.sha256" -o "$BIN_TMP/$archive.sha256" || { err "checksum download failed."; exit 1; }
  local want got
  want="$(awk '{print $1}' "$BIN_TMP/$archive.sha256")"
  got="$(sha256_of "$BIN_TMP/$archive")"
  if [ "$want" != "$got" ]; then
    err "SHA-256 mismatch — refusing to install. expected $want got $got"; exit 1
  fi
  err "checksum OK"
  tar -C "$BIN_TMP" -xzf "$BIN_TMP/$archive" || { err "archive extraction failed ($archive)."; exit 1; }
  chmod +x "$BIN_TMP"/caveman-* 2>/dev/null || true
  if ! _bins_present "$BIN_TMP"; then
    err "release archive missing required binaries — bad release for $plat."; exit 1
  fi
  echo "$BIN_TMP"
}

# ── symlink-safe deploy of one file ──────────────────────────────────────────
# Refuse to write through a symlink at the destination (or its immediate
# parent) — mirrors caveman-config's safeWriteFlag policy so a local attacker
# can't redirect the predictable hook path to clobber another file.
safe_install_file() {
  local src="$1" dst="$2" mode="$3"
  if [ -L "$dst" ]; then
    err "refusing to overwrite symlink: $dst"; return 1
  fi
  local parent; parent="$(dirname "$dst")"
  if [ -L "$parent" ]; then
    err "refusing to install under symlinked dir: $parent"; return 1
  fi
  local tmp; tmp="$(mktemp "$dst.XXXXXX")"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dst"
}

# ── idempotency probe ────────────────────────────────────────────────────────
# Already installed iff every hook binary is present in $HOOKS_DIR AND the
# settings.json references the three managed hooks (caveman-activate for
# SessionStart, caveman-hook for UserPromptSubmit, caveman-statusline for the
# badge). A substring scan suffices — `caveman-settings add` is idempotent, so a
# re-run is harmless even if this probe is conservative.
already_installed() {
  local b
  for b in "${HOOK_BINS[@]}"; do
    [ -x "$HOOKS_DIR/$b" ] || return 1
  done
  [ -f "$SETTINGS" ] || return 1
  grep -q 'caveman-activate'   "$SETTINGS" 2>/dev/null || return 1
  grep -q 'caveman-hook'       "$SETTINGS" 2>/dev/null || return 1
  grep -q 'caveman-statusline' "$SETTINGS" 2>/dev/null || return 1
  return 0
}

main() {
  local bin_dir
  bin_dir="$(resolve_bin_dir)"
  trap '[ -n "$BIN_TMP" ] && rm -rf "$BIN_TMP"' EXIT

  if [ "$FORCE" -eq 0 ] && already_installed "$bin_dir"; then
    echo "Caveman hooks already installed in $HOOKS_DIR"
    echo "  Re-run with --force to overwrite: bash src/hooks/install.sh --force"
    echo "Nothing to do. Hooks are already in place."
    return 0
  fi

  if [ "$FORCE" -eq 1 ] && [ -x "$HOOKS_DIR/caveman-activate" ]; then
    echo "Reinstalling caveman hooks (--force)..."
  else
    echo "Installing caveman hooks..."
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] would deploy into $HOOKS_DIR:"
    local b
    for b in "${HOOK_BINS[@]}"; do echo "    $b"; done
    echo "  [dry-run] would merge SessionStart + UserPromptSubmit + statusline into $SETTINGS"
    echo "  [dry-run] would run: caveman-settings add \"$HOOKS_DIR\""
    return 0
  fi

  # 1. Ensure hooks dir exists.
  mkdir -p "$HOOKS_DIR"

  # 2. Deploy each hook binary (symlink-safe, 0755).
  for b in "${HOOK_BINS[@]}"; do
    safe_install_file "$bin_dir/$b" "$HOOKS_DIR/$b" 0755 \
      || { err "failed to install $b"; exit 1; }
    echo "  Installed: $HOOKS_DIR/$b"
  done

  # 3. Wire hooks + statusline into settings.json via caveman-settings (no node).
  if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
  fi
  # Back up existing settings.json before touching it.
  cp "$SETTINGS" "$SETTINGS.bak"

  # caveman-settings reads JSON on stdin, wires the three managed hooks
  # idempotently (SessionStart→caveman-activate, UserPromptSubmit→caveman-hook,
  # statusLine→caveman-statusline), validates, and prints the merged document.
  # Statusline state is reported on stderr.
  local merged
  if merged="$("$bin_dir/caveman-settings" add "$HOOKS_DIR" < "$SETTINGS.bak")"; then
    printf '%s\n' "$merged" > "$SETTINGS"
    rm -f "$SETTINGS.bak"
    echo "  Hooks wired in $SETTINGS"
  else
    err "settings merge failed — restoring $SETTINGS from backup."
    mv -f "$SETTINGS.bak" "$SETTINGS"
    exit 1
  fi

  echo ""
  echo "Done! Restart Claude Code to activate."
  echo ""
  echo "What's installed:"
  echo "  - SessionStart hook (caveman-activate): auto-loads caveman rules every session"
  echo "  - Mode tracker hook (caveman-hook): updates statusline badge when you switch modes"
  echo "    (/caveman lite, /caveman ultra, /caveman-commit, etc.)"
  echo "  - Statusline badge (caveman-statusline): shows [CAVEMAN] or [CAVEMAN:ULTRA] etc."
  echo "  - Stats writer (caveman-stats): /caveman-stats lifetime-savings suffix"
}

main
