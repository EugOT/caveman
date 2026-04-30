#!/usr/bin/env bash
# caveman — smart multi-agent installer.
#
# One line:
#   curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
#
# Detects which AI coding agents are on your machine and installs caveman for
# each one using its native distribution (plugin / extension / skill / rule
# file). Skips agents that aren't installed. Safe to re-run — each underlying
# install command is idempotent.
#
# Flags:
#   --dry-run         List what would be installed and exit.
#   --only <agent>    Install only for the named agent (claude|gemini|codex|
#                     cursor|windsurf|cline|copilot). Repeatable.
#   --skip-skills     Don't run the npx-skills fallback.
#   --force           Re-run even if a target reports "already installed".

set -e

REPO="JuliusBrussee/caveman"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"
BIN_NAME="caveman"

DRY=0
FORCE=0
SKIP_SKILLS=0
ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY=1 ;;
    --force)       FORCE=1 ;;
    --skip-skills) SKIP_SKILLS=1 ;;
    --only)        shift; ONLY+=("$1") ;;
    -h|--help)
      cat <<EOF
caveman installer — detects your agents and installs caveman for each one.

Usage: install.sh [--dry-run] [--force] [--skip-skills] [--only <agent>]

Detected agents (anything in PATH or with a known config dir):
  claude    Claude Code         → plugin marketplace + plugin install
  gemini    Gemini CLI          → gemini extensions install
  codex     Codex CLI           → npx skills add (codex profile)
  cursor    Cursor IDE          → npx skills add (cursor profile)
  windsurf  Windsurf IDE        → npx skills add (windsurf profile)
  cline     Cline (VS Code ext) → npx skills add (cline profile)
  copilot   GitHub Copilot      → npx skills add (github-copilot profile)
  *         Anything else       → npx skills add (auto-detect fallback)
EOF
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

c_orange=$'\033[38;5;172m'
c_dim=$'\033[2m'
c_reset=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_orange" "$1" "$c_reset"; }
note() { printf '%s%s%s\n' "$c_dim" "$1" "$c_reset"; }

# ──────────────────────────────────────────────────────────────────────────
say "🪨 caveman installer"
note "  $REPO"
echo

want() {
  if [ ${#ONLY[@]} -eq 0 ]; then return 0; fi
  for a in "${ONLY[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

run() {
  if [ "$DRY" = 1 ]; then
    note "  would run: $*"
    return 0
  fi
  echo "  $ $*"
  "$@"
}

INSTALLED=()
SKIPPED=()

# ── Claude Code ────────────────────────────────────────────────────────────
if want claude && command -v claude >/dev/null 2>&1; then
  say "→ Claude Code detected"
  if [ "$FORCE" = 1 ] || ! claude plugin list 2>/dev/null | grep -qi caveman; then
    run claude plugin marketplace add "$REPO"
    run claude plugin install "caveman@caveman"
    INSTALLED+=("claude")
  else
    note "  caveman plugin already installed (use --force to reinstall)"
    SKIPPED+=("claude (already installed)")
  fi
  echo
fi

# ── Gemini CLI ─────────────────────────────────────────────────────────────
if want gemini && command -v gemini >/dev/null 2>&1; then
  say "→ Gemini CLI detected"
  if [ "$FORCE" = 1 ] || ! gemini extensions list 2>/dev/null | grep -qi caveman; then
    run gemini extensions install "https://github.com/$REPO"
    INSTALLED+=("gemini")
  else
    note "  caveman extension already installed (use --force to reinstall)"
    SKIPPED+=("gemini (already installed)")
  fi
  echo
fi

# ── Codex ──────────────────────────────────────────────────────────────────
if want codex && command -v codex >/dev/null 2>&1; then
  say "→ Codex CLI detected"
  run npx -y skills add "$REPO" -a codex
  INSTALLED+=("codex")
  echo
fi

# ── IDE rule-file targets via npx-skills ───────────────────────────────────
declare -a IDE_TARGETS
if want cursor && { command -v cursor >/dev/null 2>&1 || [ -d "$HOME/.cursor" ]; }; then
  IDE_TARGETS+=("cursor")
fi
if want windsurf && { command -v windsurf >/dev/null 2>&1 || [ -d "$HOME/.codeium/windsurf" ] || [ -d "$HOME/.windsurf" ]; }; then
  IDE_TARGETS+=("windsurf")
fi
if want cline && [ -d "$HOME/.vscode/extensions" ] && \
   ls "$HOME/.vscode/extensions" 2>/dev/null | grep -qi cline; then
  IDE_TARGETS+=("cline")
fi
if want copilot && command -v gh >/dev/null 2>&1; then
  IDE_TARGETS+=("github-copilot")
fi

for tgt in "${IDE_TARGETS[@]}"; do
  say "→ $tgt detected"
  run npx -y skills add "$REPO" -a "$tgt"
  INSTALLED+=("$tgt")
  echo
done

# ── Generic fallback: npx skills add (auto-detect) ─────────────────────────
# Only fire if (a) no --only filter was passed, (b) skills wasn't disabled,
# and (c) we neither installed nor skipped anything. Otherwise the user's
# already-installed setup or explicit --only target shouldn't be drowned in
# an unrelated fallback.
if [ "$SKIP_SKILLS" = 0 ] && [ ${#ONLY[@]} -eq 0 ] && \
   [ ${#INSTALLED[@]} -eq 0 ] && [ ${#SKIPPED[@]} -eq 0 ]; then
  say "→ no known agents detected — running npx-skills auto-detect fallback"
  if run npx -y skills add "$REPO"; then
    INSTALLED+=("skills-auto")
  fi
  echo
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
say "🪨 done"
if [ ${#INSTALLED[@]} -gt 0 ]; then
  echo "  installed for:"
  for a in "${INSTALLED[@]}"; do printf '    • %s\n' "$a"; done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "  skipped:"
  for a in "${SKIPPED[@]}"; do printf '    • %s\n' "$a"; done
fi
if [ ${#INSTALLED[@]} -eq 0 ] && [ ${#SKIPPED[@]} -eq 0 ]; then
  echo "  nothing detected. install one of: claude, gemini, cursor, windsurf, cline, codex"
  echo "  or pass --only <agent> to force a specific target"
fi

echo
note "  start any session and say 'caveman mode', or run /caveman in Claude Code"
note "  uninstall: see https://github.com/$REPO#install"
