#!/usr/bin/env bash
# caveman — installer shim (pure-Zig runtime).
#
# Downloads the prebuilt caveman Zig binaries for your platform from the latest
# GitHub Release, SHA-256-verifies the archive, and runs `caveman-install` (the
# Zig installer that detects your agents and wires up the hooks). No Node, no Zig
# toolchain required.
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --all
#
# Local clone:
#   bash install.sh [flags]      # builds from source if `zig` is present,
#                                # otherwise downloads the release binaries
#
# Windows: use install.ps1 (the Zig binaries don't yet cross-compile to Windows —
# the PowerShell path ships the shim hooks until R6-Windows lands).

set -euo pipefail

REPO="JuliusBrussee/caveman"
BIN_PREFIX="caveman"

err() { echo "caveman: $*" >&2; }

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

# ── download + verify + run the release binaries ─────────────────────────────
install_from_release() {
  command -v curl >/dev/null 2>&1 || { err "curl required."; exit 1; }
  command -v tar  >/dev/null 2>&1 || { err "tar required.";  exit 1; }

  local plat archive base tmp
  plat="$(detect_platform)"
  archive="$BIN_PREFIX-$plat.tar.gz"
  base="https://github.com/$REPO/releases/latest/download"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/caveman-install.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  echo "caveman: downloading $archive …" >&2
  curl -fsSL "$base/$archive"        -o "$tmp/$archive"        || { err "download failed ($archive). No release for $plat yet?"; exit 1; }
  curl -fsSL "$base/$archive.sha256" -o "$tmp/$archive.sha256" || { err "checksum download failed."; exit 1; }

  # Verify: the .sha256 sidecar holds "<hash>  <archive>".
  local want got
  want="$(awk '{print $1}' "$tmp/$archive.sha256")"
  got="$(sha256_of "$tmp/$archive")"
  if [ "$want" != "$got" ]; then
    err "SHA-256 mismatch — refusing to run. expected $want got $got"; exit 1
  fi
  echo "caveman: checksum OK" >&2

  tar -C "$tmp" -xzf "$tmp/$archive" || { err "archive extraction failed ($archive)."; exit 1; }
  chmod +x "$tmp"/$BIN_PREFIX-* 2>/dev/null || true
  [ -x "$tmp/$BIN_PREFIX-install" ] || { err "archive missing $BIN_PREFIX-install — bad release for $plat."; exit 1; }
  exec "$tmp/$BIN_PREFIX-install" "$@"
}

# ── local clone: build from source if zig is present ─────────────────────────
install_from_source() {
  local here="$1"; shift
  echo "caveman: building from source (zig build) …" >&2
  ( cd "$here/zig" && zig build -Dtool=caveman -Doptimize=ReleaseSafe ) || { err "zig build failed."; exit 1; }
  exec "$here/zig/zig-out/bin/$BIN_PREFIX-install" "$@"
}

# ── entry ────────────────────────────────────────────────────────────────────
# BASH_SOURCE is unset under `curl | bash`; default to empty so `set -u` is happy.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || here=""
if [ -n "$here" ] && [ -f "$here/zig/build.zig" ] && command -v zig >/dev/null 2>&1; then
  install_from_source "$here" "$@"
fi
# Local clone without zig, or curl-pipe path → download the release binaries.
install_from_release "$@"
