#!/usr/bin/env bash
# sync.sh — pull your live ~/.hammerspoon/ edits back into the repo
# Run before `git commit` so the fork tracks your customizations.
# (Symlinks don't work because Hammerspoon can't open files in ~/Documents/
# due to macOS TCC sandboxing. So we keep them as real files and sync.)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

if [[ ! -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    echo "No ~/.hammerspoon/init.lua found." >&2
    exit 1
fi

cp "$HAMMERSPOON_DIR/init.lua" "$REPO_DIR/hammerspoon/init.lua"
echo "[+] init.lua → repo"

if [[ -f "$HAMMERSPOON_DIR/overlay.html" ]]; then
    cp "$HAMMERSPOON_DIR/overlay.html" "$REPO_DIR/hammerspoon/overlay.html"
    echo "[+] overlay.html → repo"
fi

if [[ -f "$HAMMERSPOON_DIR/dashboard.html" ]]; then
    cp "$HAMMERSPOON_DIR/dashboard.html" "$REPO_DIR/hammerspoon/dashboard.html"
    echo "[+] dashboard.html → repo"
fi

# Only overwrite the example file if user's copy has diverged meaningfully.
# Prevents clobbering the upstream default voice commands with a personal set
# unless explicitly intended.
if [[ -f "$HAMMERSPOON_DIR/local_whisper_actions.lua" ]]; then
    if ! diff -q "$HAMMERSPOON_DIR/local_whisper_actions.lua" "$REPO_DIR/hammerspoon/local_whisper_actions.example.lua" >/dev/null 2>&1; then
        echo "[?] ~/.hammerspoon/local_whisper_actions.lua differs from example. Copy? [y/N]"
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            cp "$HAMMERSPOON_DIR/local_whisper_actions.lua" "$REPO_DIR/hammerspoon/local_whisper_actions.example.lua"
            echo "[+] local_whisper_actions.lua → repo"
        fi
    fi
fi

echo ""
cd "$REPO_DIR"
git status --short hammerspoon/
