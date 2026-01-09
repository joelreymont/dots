#!/bin/bash
#
# dots installer
#
# One-command install that:
#   1. Builds dots (requires Zig 0.15+)
#   2. Installs binary to ~/.local/bin/
#   3. Copies skills to ~/.claude/skills/ and ~/.codex/skills/
#   4. Configures Claude Code hooks in ~/.claude/settings.json
#
# Usage:
#   ./install.sh           # Install/update everything
#   ./install.sh --binary  # Only install binary
#   ./install.sh --skills  # Only install skills
#   ./install.sh --hooks   # Only configure hooks
#   ./install.sh --help    # Show help
#
# Safe to run multiple times - updates existing installations.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
CODEX_SKILLS_DIR="${HOME}/.codex/skills"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

# Skills to install
SKILLS=(
    "dots-plan-create"
    "dots-plan-execute"
    "dots-plan-progress"
    "dots-plan-update"
)

info() {
    echo -e "${BLUE}==>${NC} $1"
}

success() {
    echo -e "${GREEN}==>${NC} $1"
}

warn() {
    echo -e "${YELLOW}==>${NC} $1"
}

error() {
    echo -e "${RED}==>${NC} $1"
    exit 1
}

show_help() {
    cat << EOF
dots installer - Install dots CLI with Claude Code integration

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    --binary      Only build and install the binary
    --skills      Only install skills to ~/.claude/skills and ~/.codex/skills
    --hooks       Configure Claude Code hooks (TodoWrite sync - optional)
    --uninstall   Remove dots and all installed components
    --help        Show this help message

EXAMPLES:
    ./install.sh           # Install binary + skills (recommended)
    ./install.sh --binary  # Update binary only
    ./install.sh --skills  # Update skills only
    ./install.sh --hooks   # Add TodoWrite sync hooks (optional)

REQUIREMENTS:
    - Zig 0.15+ (for building from source)
    - jq (for hooks configuration, optional)

NOTE:
    Hooks are NOT installed by default. Use --hooks only if you want
    TodoWrite tasks to sync with dots (creates flat t{n}-* tasks).
    For structured ExecPlans only, skip the hooks.

EOF
}

check_zig() {
    if ! command -v zig &> /dev/null; then
        error "Zig not found. Install Zig 0.15+ from https://ziglang.org/download/"
    fi

    # Check version (need 0.15+)
    local version
    version=$(zig version 2>&1 | head -1)
    info "Found Zig: $version"
}

build_binary() {
    info "Building dots..."
    cd "$SCRIPT_DIR"

    zig build -Doptimize=ReleaseSmall

    # Strip the binary for smaller size
    if command -v strip &> /dev/null; then
        strip zig-out/bin/dot 2>/dev/null || true
    fi

    local size
    size=$(ls -lh zig-out/bin/dot | awk '{print $5}')
    success "Built: zig-out/bin/dot ($size)"
}

install_binary() {
    info "Installing binary to $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR"
    cp "$SCRIPT_DIR/zig-out/bin/dot" "$INSTALL_DIR/dot"
    chmod +x "$INSTALL_DIR/dot"

    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        warn "$INSTALL_DIR is not in PATH"
        echo "    Add to your shell config:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

    local version
    version=$("$INSTALL_DIR/dot" --version 2>&1 || echo "unknown")
    success "Installed: $version"
}

install_skills() {
    info "Installing skills..."

    mkdir -p "$CLAUDE_SKILLS_DIR"
    mkdir -p "$CODEX_SKILLS_DIR"

    local installed=0
    local updated=0

    for skill in "${SKILLS[@]}"; do
        local src="$SCRIPT_DIR/.codex/skills/$skill"

        if [[ ! -d "$src" ]]; then
            warn "Skill not found: $skill"
            continue
        fi

        # Install to Claude skills directory
        local claude_dest="$CLAUDE_SKILLS_DIR/$skill"
        if [[ -d "$claude_dest" ]]; then
            rm -rf "$claude_dest"
            ((updated++)) || true
        else
            ((installed++)) || true
        fi
        cp -r "$src" "$claude_dest"

        # Install to Codex skills directory
        local codex_dest="$CODEX_SKILLS_DIR/$skill"
        if [[ -d "$codex_dest" ]]; then
            rm -rf "$codex_dest"
        fi
        cp -r "$src" "$codex_dest"
    done

    success "Skills: $installed installed, $updated updated"
    echo "    Claude: $CLAUDE_SKILLS_DIR"
    echo "    Codex:  $CODEX_SKILLS_DIR"
}

configure_hooks() {
    info "Configuring Claude Code hooks..."

    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

    # Hooks configuration to add
    local hooks_config='{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "dot hook session"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "TodoWrite",
        "hooks": [{"type": "command", "command": "dot hook sync"}]
      }
    ]
  }
}'

    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        # Create new settings file
        echo "$hooks_config" > "$CLAUDE_SETTINGS"
        success "Created $CLAUDE_SETTINGS with hooks"
        return
    fi

    # Check if jq is available for merging
    if ! command -v jq &> /dev/null; then
        warn "jq not found - cannot merge hooks automatically"
        echo ""
        echo "Add these hooks manually to $CLAUDE_SETTINGS:"
        echo ""
        echo "$hooks_config"
        echo ""
        return
    fi

    # Check if hooks already exist
    local existing_hooks
    existing_hooks=$(jq -r '.hooks // empty' "$CLAUDE_SETTINGS" 2>/dev/null || echo "")

    if [[ -n "$existing_hooks" ]]; then
        # Merge hooks - remove any existing dots hooks (handles path variations)
        local merged
        merged=$(jq --argjson new_hooks "$hooks_config" '
            .hooks.SessionStart = (
                [.hooks.SessionStart // [] | .[] | select(.hooks[0].command | test("dot hook session") | not)] +
                $new_hooks.hooks.SessionStart
            ) |
            .hooks.PostToolUse = (
                [.hooks.PostToolUse // [] | .[] | select(.hooks[0].command | test("dot hook sync") | not)] +
                $new_hooks.hooks.PostToolUse
            )
        ' "$CLAUDE_SETTINGS")

        echo "$merged" > "$CLAUDE_SETTINGS"
        success "Merged hooks into existing $CLAUDE_SETTINGS"
    else
        # Add hooks to existing file
        local merged
        merged=$(jq --argjson new_hooks "$hooks_config" '. + $new_hooks' "$CLAUDE_SETTINGS")
        echo "$merged" > "$CLAUDE_SETTINGS"
        success "Added hooks to $CLAUDE_SETTINGS"
    fi
}

uninstall() {
    info "Uninstalling dots..."

    # Remove binary
    if [[ -f "$INSTALL_DIR/dot" ]]; then
        rm "$INSTALL_DIR/dot"
        success "Removed $INSTALL_DIR/dot"
    fi

    # Remove skills
    for skill in "${SKILLS[@]}"; do
        local claude_dest="$CLAUDE_SKILLS_DIR/$skill"
        local codex_dest="$CODEX_SKILLS_DIR/$skill"

        [[ -d "$claude_dest" ]] && rm -rf "$claude_dest"
        [[ -d "$codex_dest" ]] && rm -rf "$codex_dest"
    done
    success "Removed skills"

    # Remove hooks from settings (if jq available)
    if [[ -f "$CLAUDE_SETTINGS" ]] && command -v jq &> /dev/null; then
        local cleaned
        cleaned=$(jq '
            .hooks.SessionStart = [.hooks.SessionStart // [] | .[] | select(.hooks[0].command | test("dot hook session") | not)] |
            .hooks.PostToolUse = [.hooks.PostToolUse // [] | .[] | select(.hooks[0].command | test("dot hook sync") | not)] |
            if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end |
            if .hooks.PostToolUse == [] then del(.hooks.PostToolUse) else . end |
            if .hooks == {} then del(.hooks) else . end
        ' "$CLAUDE_SETTINGS" 2>/dev/null || cat "$CLAUDE_SETTINGS")

        echo "$cleaned" > "$CLAUDE_SETTINGS"
        success "Removed hooks from $CLAUDE_SETTINGS"
    fi

    success "Uninstall complete"
}

full_install() {
    echo ""
    echo "  dots installer"
    echo "  =============="
    echo ""

    check_zig
    build_binary
    install_binary
    install_skills

    echo ""
    success "Installation complete!"
    echo ""
    echo "  Next steps:"
    echo "    1. Restart your shell (or run: source ~/.bashrc)"
    echo "    2. Run: dot --version"
    echo "    3. Initialize in a project: dot init"
    echo ""
    echo "  Optional: Run ./install.sh --hooks to enable TodoWrite sync"
    echo ""
}

# Parse arguments
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --binary)
        check_zig
        build_binary
        install_binary
        ;;
    --skills)
        install_skills
        ;;
    --hooks)
        configure_hooks
        ;;
    --uninstall)
        uninstall
        ;;
    "")
        full_install
        ;;
    *)
        error "Unknown option: $1 (use --help for usage)"
        ;;
esac
