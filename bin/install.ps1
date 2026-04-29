# olympus-forge · install.ps1
#
# Windows mirror of bin/install.sh. Stock PowerShell 5.1+ on Windows
# 10/11, no admin required, no extra deps. Mirrors the bash script's
# three-step flow:
#
#   1. Clone (or fetch + fast-forward) FutureAI-global/olympus-forge
#      to $HOME\.olympus\forge\
#   2. Junction ~\.claude\skills\olympus-forge → $HOME\.olympus\forge
#      (junctions don't require admin or Developer Mode, unlike
#      symlinks. Claude Code's skill resolver follows them
#      transparently.)
#   3. Print the manual paste reminder for new Claude sessions
#
# Safe to re-run.
#
# Run as:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# or, if your execution policy already allows local scripts:
#   .\install.ps1

[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/FutureAI-global/olympus-forge.git",
    [string]$InstallDir = $(if ($env:OLYMPUS_FORGE_DIR) { $env:OLYMPUS_FORGE_DIR } else { Join-Path $HOME ".olympus\forge" }),
    [string]$JunctionPath = $(Join-Path $HOME ".claude\skills\olympus-forge")
)

$ErrorActionPreference = "Stop"

function Require-Cmd {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Host "✗ missing prerequisite: $Name" -ForegroundColor Red
        if ($Hint) { Write-Host "  hint: $Hint" -ForegroundColor Yellow }
        exit 1
    }
}

Write-Host "olympus-forge · install"
Write-Host ""

# --- Prerequisites ---------------------------------------------------

Require-Cmd git "winget install Git.Git, or install Git for Windows manually"
# Python isn't strictly required at install-time on Windows (the bash
# install.sh requires it because some users skip-step the python check
# entirely on Linux). The Claude-skill bin/capture-lesson DOES need it
# at runtime, but the install itself doesn't invoke python. Surface a
# WARNING not a hard error if missing.
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $pythonCmd) {
    Write-Host "⚠ python not on PATH — bin/capture-lesson requires Python 3 at runtime" -ForegroundColor Yellow
    Write-Host "  install via Microsoft Store (search 'Python 3') or python.org" -ForegroundColor Yellow
    Write-Host "  install will continue; capture-lesson invocations will fail until python is present" -ForegroundColor Yellow
} else {
    Write-Host "✓ git + python present"
}

# --- Clone or update -------------------------------------------------

$gitDir = Join-Path $InstallDir ".git"
if (Test-Path $gitDir) {
    Write-Host "✓ existing checkout: $InstallDir"
    Write-Host "  fetching + fast-forward only…"
    & git -C $InstallDir fetch --quiet origin
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ git fetch failed (network? auth?)" -ForegroundColor Red
        exit 1
    }
    # Fast-forward-only against the current branch's upstream. If the
    # local has divergent commits, stop before clobbering them.
    $currentBranch = & git -C $InstallDir rev-parse --abbrev-ref HEAD
    & git -C $InstallDir merge --ff-only --quiet "origin/$currentBranch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Try origin/HEAD as a fallback (when current branch has no
        # upstream — e.g. initial state right after clone).
        & git -C $InstallDir merge --ff-only --quiet "origin/HEAD" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✗ fast-forward failed (local has divergent commits)" -ForegroundColor Red
            Write-Host "  resolve in $InstallDir then re-run install.ps1" -ForegroundColor Yellow
            exit 1
        }
    }
    $sha = (& git -C $InstallDir rev-parse --short HEAD).Trim()
    Write-Host "✓ updated to $sha"
} else {
    Write-Host "→ cloning $RepoUrl → $InstallDir"
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    & git clone --quiet --depth=1 $RepoUrl $InstallDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ git clone failed (network? auth?)" -ForegroundColor Red
        exit 1
    }
    $sha = (& git -C $InstallDir rev-parse --short HEAD).Trim()
    Write-Host "✓ cloned at $sha"
}

# --- Junction --------------------------------------------------------
#
# Why junction not symlink: real symlinks on Windows require admin OR
# Developer Mode (post-Win10 1703 with `mklink` policy). Junctions
# (`mklink /J`) work for everyone with no special privilege. Claude
# Code's skill resolver follows junctions transparently — it sees a
# directory at that path and reads its contents, doesn't care about
# the underlying mechanism. Junctions only work for directories on the
# same volume; cross-drive needs a real symlink.

$junctionParent = Split-Path -Parent $JunctionPath
if (-not (Test-Path $junctionParent)) { New-Item -ItemType Directory -Path $junctionParent -Force | Out-Null }

if (Test-Path $JunctionPath) {
    $existing = Get-Item $JunctionPath -Force
    $isReparse = $existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint
    if ($isReparse) {
        # Existing junction or symlink. Resolve target.
        $targetRaw = (& fsutil reparsepoint query $JunctionPath 2>$null) -join "`n"
        if ($targetRaw -match [regex]::Escape($InstallDir)) {
            Write-Host "✓ junction already points at canonical install: $JunctionPath"
        } else {
            Write-Host "→ refreshing junction: $JunctionPath → $InstallDir"
            & cmd /c rmdir $JunctionPath
            & cmd /c mklink /J $JunctionPath $InstallDir | Out-Null
        }
    } else {
        Write-Host "✗ $JunctionPath exists and is NOT a junction or symlink" -ForegroundColor Red
        Write-Host "  back up your local skills then remove this path before re-running" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "→ creating junction: $JunctionPath → $InstallDir"
    & cmd /c mklink /J $JunctionPath $InstallDir | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ mklink failed" -ForegroundColor Red
        Write-Host "  alternative: enable Developer Mode then create a real symlink with:" -ForegroundColor Yellow
        Write-Host "    New-Item -ItemType SymbolicLink -Path '$JunctionPath' -Target '$InstallDir'" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "✓ junction created"
}

# --- Done ------------------------------------------------------------

Write-Host ""
Write-Host "──────────────────────────────────────────────────────"
Write-Host "olympus-forge installed."
Write-Host ""
Write-Host "Next: paste DISTRIBUTE.md into every Claude session you run"
Write-Host "so each session joins the cross-session learnings pool."
Write-Host ""
Write-Host "  type $InstallDir\DISTRIBUTE.md"
Write-Host ""
Write-Host "Re-run this script anytime to pull updates from canonical."
Write-Host "──────────────────────────────────────────────────────"
