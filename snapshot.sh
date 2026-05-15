#!/usr/bin/env bash
# Capture current OS config state into this repo and push.
# Run from any directory — it always operates on the repo it lives in.
#
# What gets snapshotted:
#   - Zen browser mods + keyboard shortcuts (from active profile)
#   - VS Code settings
#   - Git config
#   - opencode config
#   - GNOME extension list (informational)
#   - Dotfiles are symlinked so always current; no action needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

# Copy a single file into the dotfiles tree, skipping if source doesn't exist.
capture() {
    local src="$1" rel="$2"
    local dest="$SCRIPT_DIR/dotfiles/$rel"
    if [[ ! -f "$src" ]]; then
        log_warn "Not found: $src — skipping"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    log_info "Captured $rel"
}

# ─── Zen ──────────────────────────────────────────────────────────────────────

log_section "Zen browser"

ZEN_PROFILE_PATH=$(grep '^Path=' "$HOME/.config/zen/profiles.ini" 2>/dev/null | head -1 | cut -d= -f2 || true)

if [[ -z "$ZEN_PROFILE_PATH" ]]; then
    log_warn "No Zen profile found — skipping"
else
    ZEN_PROFILE="$HOME/.config/zen/$ZEN_PROFILE_PATH"
    for f in zen-themes.json zen-keyboard-shortcuts.json; do
        capture "$ZEN_PROFILE/$f" ".config/zen/$f"
    done
fi

# ─── VS Code ──────────────────────────────────────────────────────────────────

log_section "VS Code"

VSCODE_USER="$HOME/.config/Code/User"
capture "$VSCODE_USER/settings.json"    ".config/Code/User/settings.json"
capture "$VSCODE_USER/keybindings.json" ".config/Code/User/keybindings.json"

# ─── Git ──────────────────────────────────────────────────────────────────────

log_section "Git"

capture "$HOME/.gitconfig"      ".gitconfig"
capture "$HOME/.gitconfig-work" ".gitconfig-work"

# ─── opencode ─────────────────────────────────────────────────────────────────

log_section "opencode"

capture "$HOME/.config/opencode/opencode.jsonc" ".config/opencode/opencode.jsonc"

# ─── GNOME ────────────────────────────────────────────────────────────────────

log_section "GNOME"

if command -v gsettings &>/dev/null; then
    ENABLED_EXTS=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
    [[ -n "$ENABLED_EXTS" ]] && log_info "Enabled extensions: $ENABLED_EXTS"
    log_info "GNOME settings are managed by sync-gnome.sh — edit that file to change them"
else
    log_warn "gsettings not available — skipping"
fi

# ─── Commit & push ────────────────────────────────────────────────────────────

log_section "Commit"

cd "$SCRIPT_DIR"

if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    log_info "Nothing changed — repo already up to date"
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
CHANGED=$(git diff --name-only; git ls-files --others --exclude-standard)
SUMMARY=$(echo "$CHANGED" | sed 's|dotfiles/||g; s|\.config/||g' | sort -u | paste -sd ', ')

git add -A
git commit -m "snapshot: $TIMESTAMP — $SUMMARY"
git push

log_info "Snapshot committed and pushed."
