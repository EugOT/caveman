# caveman — smart multi-agent installer (Windows / PowerShell).
#
# One line:
#   irm https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.ps1 | iex
#
# Detects which AI coding agents are on your machine and installs caveman for
# each one using its native distribution. Skips agents that aren't installed.
# Safe to re-run.
#
# Flags:
#   -DryRun       List what would be installed and exit.
#   -Only <list>  Comma-separated agent list (claude,gemini,codex,cursor,
#                 windsurf,cline,copilot).
#   -SkipSkills   Don't run the npx-skills fallback.
#   -Force        Re-run even if a target reports "already installed".

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Force,
  [switch]$SkipSkills,
  [string]$Only = ""
)

$ErrorActionPreference = "Stop"
$Repo = "JuliusBrussee/caveman"
$OnlyList = if ($Only) { $Only.Split(',') | ForEach-Object { $_.Trim() } } else { @() }

function Say($msg)  { Write-Host $msg -ForegroundColor DarkYellow }
function Note($msg) { Write-Host $msg -ForegroundColor DarkGray }

function Want($name) {
  if ($OnlyList.Count -eq 0) { return $true }
  return $OnlyList -contains $name
}

function Has($cmd) {
  return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Run {
  param([string]$Cmd, [string[]]$Args)
  if ($DryRun) {
    Note "  would run: $Cmd $($Args -join ' ')"
    return $true
  }
  Write-Host "  $ $Cmd $($Args -join ' ')"
  try {
    & $Cmd @Args
    return $LASTEXITCODE -eq 0
  } catch {
    Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

Say "🪨 caveman installer"
Note "  $Repo"
Write-Host ""

$Installed = @()
$Skipped = @()

# ── Claude Code ────────────────────────────────────────────────────────────
if ((Want "claude") -and (Has "claude")) {
  Say "→ Claude Code detected"
  $alreadyInstalled = $false
  if (-not $Force) {
    try {
      $list = & claude plugin list 2>$null
      if ($list -match "(?i)caveman") { $alreadyInstalled = $true }
    } catch {}
  }
  if ($alreadyInstalled) {
    Note "  caveman plugin already installed (use -Force to reinstall)"
    $Skipped += "claude (already installed)"
  } else {
    Run "claude" @("plugin", "marketplace", "add", $Repo) | Out-Null
    Run "claude" @("plugin", "install", "caveman@caveman") | Out-Null
    $Installed += "claude"
  }
  Write-Host ""
}

# ── Gemini CLI ─────────────────────────────────────────────────────────────
if ((Want "gemini") -and (Has "gemini")) {
  Say "→ Gemini CLI detected"
  $alreadyInstalled = $false
  if (-not $Force) {
    try {
      $list = & gemini extensions list 2>$null
      if ($list -match "(?i)caveman") { $alreadyInstalled = $true }
    } catch {}
  }
  if ($alreadyInstalled) {
    Note "  caveman extension already installed (use -Force to reinstall)"
    $Skipped += "gemini (already installed)"
  } else {
    Run "gemini" @("extensions", "install", "https://github.com/$Repo") | Out-Null
    $Installed += "gemini"
  }
  Write-Host ""
}

# ── Codex ──────────────────────────────────────────────────────────────────
if ((Want "codex") -and (Has "codex")) {
  Say "→ Codex CLI detected"
  Run "npx" @("-y", "skills", "add", $Repo, "-a", "codex") | Out-Null
  $Installed += "codex"
  Write-Host ""
}

# ── IDE rule-file targets via npx-skills ───────────────────────────────────
$IdeTargets = @()
if ((Want "cursor") -and ((Has "cursor") -or (Test-Path "$HOME\.cursor"))) {
  $IdeTargets += "cursor"
}
if ((Want "windsurf") -and ((Has "windsurf") -or
                            (Test-Path "$HOME\.codeium\windsurf") -or
                            (Test-Path "$HOME\.windsurf"))) {
  $IdeTargets += "windsurf"
}
if ((Want "cline") -and (Test-Path "$HOME\.vscode\extensions")) {
  $clineExt = Get-ChildItem "$HOME\.vscode\extensions" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match "(?i)cline" }
  if ($clineExt) { $IdeTargets += "cline" }
}
if ((Want "copilot") -and (Has "gh")) { $IdeTargets += "github-copilot" }

foreach ($tgt in $IdeTargets) {
  Say "→ $tgt detected"
  Run "npx" @("-y", "skills", "add", $Repo, "-a", $tgt) | Out-Null
  $Installed += $tgt
  Write-Host ""
}

# ── Generic fallback: npx skills add (auto-detect) ─────────────────────────
# Only fire if (a) no -Only filter, (b) skills not disabled, (c) we neither
# installed nor skipped anything. Otherwise skip — see install.sh comment.
if (-not $SkipSkills -and $OnlyList.Count -eq 0 -and
    $Installed.Count -eq 0 -and $Skipped.Count -eq 0) {
  Say "→ no known agents detected — running npx-skills auto-detect fallback"
  if (Run "npx" @("-y", "skills", "add", $Repo)) { $Installed += "skills-auto" }
  Write-Host ""
}

# ── Summary ────────────────────────────────────────────────────────────────
Write-Host ""
Say "🪨 done"
if ($Installed.Count -gt 0) {
  Write-Host "  installed for:"
  foreach ($a in $Installed) { Write-Host "    • $a" }
}
if ($Skipped.Count -gt 0) {
  Write-Host "  skipped:"
  foreach ($a in $Skipped) { Write-Host "    • $a" }
}
if ($Installed.Count -eq 0 -and $Skipped.Count -eq 0) {
  Write-Host "  nothing detected. install one of: claude, gemini, cursor, windsurf, cline, codex"
  Write-Host "  or pass -Only <agent> to force a specific target"
}

Write-Host ""
Note "  start any session and say 'caveman mode', or run /caveman in Claude Code"
Note "  uninstall: see https://github.com/$Repo#install"
