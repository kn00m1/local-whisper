#!/usr/bin/env bash
# install.sh — Thinking Out Loud installer
# Sets up everything needed for hold-to-dictate on macOS with whisper.cpp
# Architecture: Hammerspoon-only (no Karabiner, no bash scripts at runtime)
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }

# ─── Interactive prompts must work when piped (curl | bash) ─────────────────
# Only redirect if /dev/tty can actually be opened (probe in a subshell so a
# failed open doesn't abort the script under set -e / headless runs)
if [[ ! -t 0 ]] && ( : </dev/tty ) 2>/dev/null; then
    exec </dev/tty
fi

# ─── Detect script location (repo root) ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Curl-mode bootstrap: fetch the repo if we're running standalone ────────
# When invoked via `curl ... | bash`, there is no repo next to the script.
# Clone (shallow) into ~/.thinking-out-loud/src and re-exec from there.
REPO_URL="https://github.com/kn00m1/thinking-out-loud"
if [[ ! -f "$SCRIPT_DIR/hammerspoon/init.lua" ]]; then
    SRC_DIR="$HOME/.thinking-out-loud/src"
    info "Running standalone — fetching Thinking Out Loud into $SRC_DIR"
    if ! command -v git &>/dev/null; then
        error "git not found. Install Xcode Command Line Tools first: xcode-select --install"
        exit 1
    fi
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" pull --ff-only || warn "Could not update existing checkout — using it as-is"
    else
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --depth 1 "$REPO_URL" "$SRC_DIR"
    fi
    exec bash "$SRC_DIR/install.sh" "$@"
fi

# ─── Configurable paths ─────────────────────────────────────────────────────
WHISPER_CPP_DIR="$HOME/whisper.cpp"
WHISPER_MODEL="medium"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

# ─── Preflight ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Thinking Out Loud installer${NC}"
echo -e "Hold a key → speak → release → text at cursor"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This tool is macOS-only."
    exit 1
fi

# Check Apple Silicon
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon detected ($ARCH)"
else
    warn "Intel Mac detected ($ARCH) — will work but transcription will be slower"
fi

# Check Homebrew
if ! command -v brew &>/dev/null; then
    error "Homebrew not found. Install it first: https://brew.sh"
    exit 1
fi
ok "Homebrew found"

# ─── Step 1: Brew dependencies ──────────────────────────────────────────────
echo ""
info "Step 1/7: Installing dependencies via Homebrew..."

BREW_FORMULAE=(ffmpeg git)
for formula in "${BREW_FORMULAE[@]}"; do
    if brew list "$formula" &>/dev/null; then
        ok "$formula already installed"
    else
        info "Installing $formula..."
        brew install "$formula"
        ok "$formula installed"
    fi
done

if brew list --cask hammerspoon &>/dev/null; then
    ok "hammerspoon already installed"
else
    info "Installing hammerspoon..."
    brew install --cask hammerspoon
    ok "hammerspoon installed"
fi

# ─── Step 2: Install whisper.cpp (brew bottle preferred, source fallback) ───
echo ""
info "Step 2/7: Installing whisper.cpp..."

# init.lua prefers a source build at ~/whisper.cpp/build/bin/whisper-cli and
# falls back to the Homebrew binary. Models always live in ~/whisper.cpp/models.
if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
    ok "whisper-cli already built at $WHISPER_CPP_DIR/build/bin/whisper-cli"
elif brew list whisper-cpp &>/dev/null; then
    ok "whisper-cpp already installed via Homebrew ($(command -v whisper-cli || echo "$(brew --prefix)/bin/whisper-cli"))"
elif brew install whisper-cpp; then
    ok "whisper-cpp installed via Homebrew (prebuilt, Metal-enabled)"
else
    warn "Homebrew install failed — building whisper.cpp from source instead"
    brew list cmake &>/dev/null || brew install cmake
    if [[ ! -d "$WHISPER_CPP_DIR" ]]; then
        info "Cloning whisper.cpp..."
        git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
    fi
    info "Building with cmake (this may take a few minutes)..."
    cd "$WHISPER_CPP_DIR"
    cmake -B build
    cmake --build build -j --config Release
    cd "$SCRIPT_DIR"
    if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
        ok "whisper-cli built successfully"
    else
        error "Build failed — check output above"
        exit 1
    fi
fi

# ─── Step 3: Download models ────────────────────────────────────────────────
echo ""
info "Step 3/7: Downloading whisper models..."

# Models always live in ~/whisper.cpp/models regardless of how the binary was
# installed (brew bottle or source build) — init.lua reads them from there.
MODELS_DIR="$WHISPER_CPP_DIR/models"
mkdir -p "$MODELS_DIR"

# download_model <name> — fetch ggml-<name>.bin from Hugging Face if missing
download_model() {
    local name="$1" dest="$MODELS_DIR/ggml-$1.bin"
    if [[ -f "$dest" ]]; then
        ok "Model already downloaded: ggml-${name}.bin"
        return 0
    fi
    info "Downloading ggml-${name}.bin..."
    if curl -fL --progress-bar -o "$dest.tmp" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${name}.bin"; then
        mv "$dest.tmp" "$dest"
        ok "Model downloaded: ggml-${name}.bin"
    else
        rm -f "$dest.tmp"
        return 1
    fi
}

if ! download_model "$WHISPER_MODEL"; then
    error "Model download failed"
    exit 1
fi

# Also download tiny model for faster live preview (~75 MB)
if ! download_model tiny; then
    warn "Tiny model download failed — live preview will use main model (slower but works)"
fi

# ─── Step 4: Install Hammerspoon config ─────────────────────────────────────
echo ""
info "Step 4/7: Setting up Hammerspoon..."

mkdir -p "$HAMMERSPOON_DIR"

# Create config directory for user settings
CONFIG_DIR="$HOME/.thinking-out-loud"
mkdir -p "$CONFIG_DIR"
ok "Config directory: $CONFIG_DIR"

if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    # Detect a managed install by either brand marker. "thinking-out-loud" is the
    # durable anchor (CONFIG_DIR + paths in init.lua); "local-whisper" preserves
    # backward-compat with pre-rebrand installs.
    if grep -qE "local-whisper|thinking-out-loud" "$HAMMERSPOON_DIR/init.lua"; then
        # Existing local-whisper config — update it but preserve user settings
        # (user settings live in ~/.thinking-out-loud/, not in init.lua)
        cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
        ok "Hammerspoon config updated"
    else
        warn "Existing init.lua found — backing up to init.lua.backup"
        cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
        cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
        ok "Hammerspoon config installed (backup saved)"
    fi
else
    cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
    ok "Hammerspoon config installed"
fi

# Install example voice commands if user doesn't have a config yet
if [[ ! -f "$HAMMERSPOON_DIR/local_whisper_actions.lua" ]]; then
    if [[ -f "$SCRIPT_DIR/hammerspoon/local_whisper_actions.example.lua" ]]; then
        cp "$SCRIPT_DIR/hammerspoon/local_whisper_actions.example.lua" "$HAMMERSPOON_DIR/local_whisper_actions.lua"
        ok "Voice commands config installed (edit ~/.hammerspoon/local_whisper_actions.lua to customize)"
    fi
fi

# Install example dictionary if user doesn't have one yet
if [[ ! -f "$CONFIG_DIR/dictionary.json" ]]; then
    if [[ -f "$SCRIPT_DIR/hammerspoon/dictionary.example.json" ]]; then
        cp "$SCRIPT_DIR/hammerspoon/dictionary.example.json" "$CONFIG_DIR/dictionary.json"
        ok "Dictionary installed (edit ~/.thinking-out-loud/dictionary.json to customize)"
    fi
fi

# ─── Step 5: Setup (permissions, trigger key, audio device, HS CLI) ─────────
echo ""
info "Step 5/7: Running setup (permissions, trigger key, audio device)..."
echo ""
bash "$SCRIPT_DIR/setup.sh"

# ─── Step 6: Optional — Ollama for LLM refinement ───────────────────────────
echo ""
info "Step 6/7: LLM refinement (optional)"
echo ""
echo "  Refinement cleans up transcripts with a small local LLM via Ollama"
echo "  (removes fillers, fixes punctuation). Fully offline. ~1.4 GB download."
echo ""
read -r -p "  Install Ollama + qwen3:1.7b for refinement? [y/N]: " INSTALL_OLLAMA

if [[ "$INSTALL_OLLAMA" =~ ^[Yy]$ ]]; then
    if command -v ollama &>/dev/null; then
        ok "Ollama already installed"
    else
        info "Installing Ollama..."
        brew install ollama
        ok "Ollama installed"
    fi
    # Make sure the server is up before pulling
    if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null; then
        info "Starting Ollama service..."
        brew services start ollama 2>/dev/null || (ollama serve &>/dev/null &)
        for _ in $(seq 1 15); do
            curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null && break
            sleep 1
        done
    fi
    if curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null; then
        info "Pulling qwen3:1.7b (~1.4 GB)..."
        if ollama pull qwen3:1.7b; then
            echo "qwen3:1.7b" > "$CONFIG_DIR/refine_model"
            echo "on" > "$CONFIG_DIR/refine"
            ok "Refinement enabled (model: qwen3:1.7b)"
        else
            warn "Model pull failed — enable later with: ollama pull qwen3:1.7b"
        fi
    else
        warn "Ollama server didn't come up — enable refinement later from the menu bar"
    fi
else
    ok "Skipped (refine can be enabled later: brew install ollama && ollama pull qwen3:1.7b)"
fi

# ─── Step 7: Optional — BlackHole for meeting recording ──────────────────────
echo ""
info "Step 7/7: Meeting recording mode (optional)"
echo ""
echo "  Meeting mode captures system audio during calls and generates"
echo "  transcripts + AI summaries. Requires BlackHole (free virtual audio driver)."
echo ""
read -r -p "  Install BlackHole for meeting recording? [y/N]: " INSTALL_BH

if [[ "$INSTALL_BH" =~ ^[Yy]$ ]]; then
    if brew list --cask blackhole-2ch &>/dev/null; then
        ok "BlackHole 2ch already installed"
    else
        info "Installing BlackHole 2ch..."
        brew install --cask blackhole-2ch
        ok "BlackHole 2ch installed"
    fi

    echo ""
    echo -e "  ${BOLD}One manual step needed:${NC} create a Multi-Output Device"
    echo ""
    echo "  1. Audio MIDI Setup will open (or find it via Spotlight)"
    echo "  2. Click '+' at bottom left → Create Multi-Output Device"
    echo "  3. Check BOTH your speakers/headphones AND BlackHole 2ch"
    echo "  4. Right-click the new device → Use This Device For Sound Output"
    echo ""
    echo "  This routes audio to both your ears and BlackHole for recording."
    echo ""
    open "/Applications/Utilities/Audio MIDI Setup.app" 2>/dev/null || true
    read -r -p "  Press Enter when done..."
    ok "Meeting mode ready — start from the menu bar icon"
else
    ok "Skipped (you can set up meeting mode later from the menu bar)"
fi
