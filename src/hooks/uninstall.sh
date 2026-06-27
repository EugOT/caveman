#!/usr/bin/env bash
# caveman — uninstaller for the SessionStart + UserPromptSubmit hooks (pure-Zig).
#
# Removes: the Zig hook binaries in ~/.claude/hooks, the caveman entries in
# settings.json (via the `caveman-settings` binary — no Node), and the flag file.
#
# Usage: bash src/hooks/uninstall.sh
#   or:  bash <(curl -s https://raw.githubusercontent.com/JuliusBrussee/caveman/main/src/hooks/uninstall.sh)
#   or:  bash src/hooks/uninstall.sh --dry-run
set -euo pipefail

REPO="JuliusBrussee/caveman"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

err() { echo "caveman: $*" >&2; }

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
FLAG_FILE="$CLAUDE_DIR/.caveman-active"

# Hook binaries we deploy, plus the legacy JS/shell filenames so an upgrade from
# a pre-R6.3 install also cleans up the old artifacts.
HOOK_BINS=(caveman-activate caveman-hook caveman-statusline caveman-stats)
LEGACY_HOOK_FILES=(
  package.json
  caveman-config.js
  caveman-activate.js
  caveman-mode-tracker.js
  caveman-stats.js
  caveman-statusline.sh
  caveman-statusline.ps1
)

# ── platform / checksum helpers (mirror install.sh) ──────────────────────────
detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) return 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

# ── resolve a caveman-settings binary for the settings.json edit ─────────────
# Best-effort, in priority order:
#   1. the freshly-installed hooks dir copy (if a prior install left it)
#   2. a local clone build at zig/zig-out/bin (build if `zig` present)
#   3. download the per-platform release archive + SHA-256 verify
# Echoes the path to caveman-settings on stdout, or empty if unobtainable.
# May set BIN_TMP (caller cleans).
BIN_TMP=""
resolve_settings_bin() {
  # (1) hooks dir copy.
  if [ -x "$HOOKS_DIR/caveman-settings" ]; then
    echo "$HOOKS_DIR/caveman-settings"; return 0
  fi
  # (2) local clone.
  local script_dir repo_root
  script_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
  fi
  if [ -n "$script_dir" ]; then
    repo_root="$(cd "$script_dir/../.." 2>/dev/null && pwd)" || repo_root=""
    if [ -n "$repo_root" ]; then
      if [ -x "$repo_root/zig/zig-out/bin/caveman-settings" ]; then
        echo "$repo_root/zig/zig-out/bin/caveman-settings"; return 0
      fi
      if [ -f "$repo_root/zig/build.zig" ] && command -v zig >/dev/null 2>&1; then
        err "building caveman-settings from source (zig build) …"
        ( cd "$repo_root/zig" && zig build -Dtool=caveman -Doptimize=ReleaseSafe ) >&2 || true
        if [ -x "$repo_root/zig/zig-out/bin/caveman-settings" ]; then
          echo "$repo_root/zig/zig-out/bin/caveman-settings"; return 0
        fi
      fi
    fi
  fi
  # (3) download the release archive (best effort — no hard failure).
  local plat archive base want got
  plat="$(detect_platform)" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v tar  >/dev/null 2>&1 || return 1
  archive="caveman-$plat.tar.gz"
  base="https://github.com/$REPO/releases/latest/download"
  BIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/caveman-uninstall.XXXXXX")"
  curl -fsSL "$base/$archive"        -o "$BIN_TMP/$archive"        >/dev/null 2>&1 || return 1
  curl -fsSL "$base/$archive.sha256" -o "$BIN_TMP/$archive.sha256" >/dev/null 2>&1 || return 1
  want="$(awk '{print $1}' "$BIN_TMP/$archive.sha256")"
  got="$(sha256_of "$BIN_TMP/$archive")" || return 1
  [ "$want" = "$got" ] || { err "checksum mismatch on $archive — not using downloaded binary."; return 1; }
  tar -C "$BIN_TMP" -xzf "$BIN_TMP/$archive" >/dev/null 2>&1 || return 1
  chmod +x "$BIN_TMP"/caveman-* 2>/dev/null || true
  [ -x "$BIN_TMP/caveman-settings" ] || return 1
  echo "$BIN_TMP/caveman-settings"; return 0
}

# Detect if caveman is installed as a plugin (check plugin cache).
PLUGIN_INSTALLED=0
if [ -d "$CLAUDE_DIR/plugins" ]; then
  if find "$CLAUDE_DIR/plugins" -path "*/caveman*" -name "plugin.json" -print -quit 2>/dev/null | grep -q .; then
    PLUGIN_INSTALLED=1
  fi
fi

if [ "$PLUGIN_INSTALLED" -eq 1 ]; then
  echo "Caveman appears to be installed as a Claude Code plugin."
  echo "To uninstall the plugin, run:"
  echo ""
  echo "  claude plugin disable caveman"
  echo ""
  echo "This script removes standalone hooks (installed via install.sh)."
  echo "Continuing with standalone hook removal..."
  echo ""
fi

echo "Uninstalling caveman hooks..."

# Resolve the settings binary BEFORE deleting the hooks dir copy, so step 2 can
# still edit settings.json after step 1 removes the in-dir binary.
SETTINGS_BIN="$(resolve_settings_bin || true)"
trap '[ -n "$BIN_TMP" ] && rm -rf "$BIN_TMP"' EXIT

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  [dry-run] would remove hook binaries from $HOOKS_DIR:"
  for b in "${HOOK_BINS[@]}"; do [ -e "$HOOKS_DIR/$b" ] && echo "    $b"; done
  echo "  [dry-run] would remove legacy hook files (if present)"
  if [ -n "$SETTINGS_BIN" ]; then
    echo "  [dry-run] would run: caveman-settings remove caveman < $SETTINGS"
  else
    echo "  [dry-run] caveman-settings unavailable — would warn to edit $SETTINGS manually"
  fi
  echo "  [dry-run] would remove flag file $FLAG_FILE"
  exit 0
fi

# 1. Remove hook binaries (current) + legacy JS/shell hook files.
REMOVED_FILES=0
for f in "${HOOK_BINS[@]}" "${LEGACY_HOOK_FILES[@]}"; do
  if [ -e "$HOOKS_DIR/$f" ] && [ ! -L "$HOOKS_DIR/$f" ]; then
    rm -f "$HOOKS_DIR/$f"
    echo "  Removed: $HOOKS_DIR/$f"
    REMOVED_FILES=$((REMOVED_FILES + 1))
  fi
done
if [ "$REMOVED_FILES" -eq 0 ]; then
  echo "  No hook files found in $HOOKS_DIR"
fi

# 2. Remove caveman entries from settings.json via caveman-settings (no node).
if [ -f "$SETTINGS" ]; then
  if [ -z "$SETTINGS_BIN" ]; then
    err "caveman-settings binary not found — cannot safely edit settings.json."
    err "       Remove the caveman SessionStart, UserPromptSubmit, and statusLine"
    err "       entries from $SETTINGS manually."
  else
    cp "$SETTINGS" "$SETTINGS.bak"
    if stripped="$("$SETTINGS_BIN" remove caveman < "$SETTINGS.bak")"; then
      printf '%s\n' "$stripped" > "$SETTINGS"
      rm -f "$SETTINGS.bak"
      echo "  Removed caveman hook + statusLine entries from settings.json"
    else
      err "settings edit failed — restoring $SETTINGS from backup."
      mv -f "$SETTINGS.bak" "$SETTINGS"
    fi
  fi
fi

# 3. Remove flag file.
if [ -f "$FLAG_FILE" ] && [ ! -L "$FLAG_FILE" ]; then
  rm -f "$FLAG_FILE"
  echo "  Removed: $FLAG_FILE"
fi

echo ""
echo "Done! Restart Claude Code to complete the uninstall."

# Guidance for other agents.
echo ""
echo "Other agents:"
echo "  npx skills remove caveman    # Cursor, Windsurf, Cline, Copilot, etc."
echo "  claude plugin disable caveman  # Claude Code plugin"
echo "  gemini extensions uninstall caveman  # Gemini CLI"
