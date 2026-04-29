#!/usr/bin/env bash
# olympus-forge · install.sh
#
# Idempotent, minimal install for the cross-session skills pack on
# Linux + macOS. Mirrors what DISTRIBUTE.md describes manually:
#
#   1. Clone (or fetch + fast-forward) FutureAI-global/olympus-forge
#      to ~/.olympus/forge/
#   2. Symlink ~/.claude/skills/olympus-forge → ~/.olympus/forge so
#      Claude Code's skill resolver picks up the canonical content
#   3. Print the manual paste reminder for new Claude sessions
#
# Safe to re-run: skips clone if already present; refreshes the symlink
# if the target moved; uses fast-forward-only for git pulls so divergent
# local edits stop the script before silent loss.
#
# Windows users: see install.ps1 for the PowerShell mirror (stock
# Windows 10/11, PowerShell 5.1+, no admin required).

set -euo pipefail

REPO_URL="https://github.com/FutureAI-global/olympus-forge.git"
INSTALL_DIR="${OLYMPUS_FORGE_DIR:-$HOME/.olympus/forge}"
SYMLINK_PATH="$HOME/.claude/skills/olympus-forge"

echo "olympus-forge · install"
echo

# --- Prerequisites ---------------------------------------------------

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "✗ missing prerequisite: $1" >&2
    [ -n "${2:-}" ] && echo "  hint: $2" >&2
    exit 1
  fi
}

require git "install via your package manager (apt / brew / dnf)"
require python3 "Python 3 is required by bin/capture-lesson"
echo "✓ git + python3 present"

# --- Clone or update -------------------------------------------------

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "✓ existing checkout: $INSTALL_DIR"
  echo "  fetching + fast-forward only…"
  git -C "$INSTALL_DIR" fetch --quiet origin
  # Fast-forward-only: if the local checkout has divergent commits, stop
  # before clobbering them. Caller can resolve manually then re-run.
  if ! git -C "$INSTALL_DIR" merge --ff-only --quiet origin/HEAD 2>/dev/null \
    && ! git -C "$INSTALL_DIR" merge --ff-only --quiet "origin/$(git -C "$INSTALL_DIR" symbolic-ref --short HEAD)" 2>/dev/null; then
    echo "✗ fast-forward failed (local has divergent commits)" >&2
    echo "  resolve in $INSTALL_DIR then re-run install.sh" >&2
    exit 1
  fi
  echo "✓ updated to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
else
  echo "→ cloning $REPO_URL → $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet --depth=1 "$REPO_URL" "$INSTALL_DIR"
  echo "✓ cloned at $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
fi

# --- Symlink ---------------------------------------------------------

mkdir -p "$(dirname "$SYMLINK_PATH")"

if [ -L "$SYMLINK_PATH" ]; then
  current_target="$(readlink "$SYMLINK_PATH")"
  if [ "$current_target" = "$INSTALL_DIR" ]; then
    echo "✓ symlink already points at canonical install: $SYMLINK_PATH"
  else
    echo "→ refreshing symlink: $SYMLINK_PATH → $INSTALL_DIR (was $current_target)"
    rm "$SYMLINK_PATH"
    ln -s "$INSTALL_DIR" "$SYMLINK_PATH"
  fi
elif [ -e "$SYMLINK_PATH" ]; then
  echo "✗ $SYMLINK_PATH exists and is NOT a symlink" >&2
  echo "  back up your local skills then remove this path before re-running" >&2
  exit 1
else
  echo "→ creating symlink: $SYMLINK_PATH → $INSTALL_DIR"
  ln -s "$INSTALL_DIR" "$SYMLINK_PATH"
  echo "✓ symlink created"
fi

# --- Done ------------------------------------------------------------

echo
echo "──────────────────────────────────────────────────────"
echo "olympus-forge installed."
echo
echo "Next: paste DISTRIBUTE.md into every Claude session you run"
echo "so each session joins the cross-session learnings pool."
echo
echo "  cat $INSTALL_DIR/DISTRIBUTE.md"
echo
echo "Re-run this script anytime to pull updates from canonical."
echo "──────────────────────────────────────────────────────"
