#!/usr/bin/env bash
# Fedora post-install setup script
# Run as your regular user (not root), from a desktop session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.fedora-setup.log"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/checks.sh"

# ─── Section 2: Git Config ────────────────────────────────────────────────────

configure_git() {
    log_section "Section 2: Git Configuration"

    if [[ -f "$HOME/.gitconfig" ]]; then
        log_warn "~/.gitconfig already exists, skipping"
        return
    fi

    read -rp "Git name:  " GIT_NAME
    read -rp "Git email: " GIT_EMAIL
    git config --global user.name  "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    log_info "Git config written."
}

# ─── Section 3: Repositories ─────────────────────────────────────────────────

enable_repos() {
    log_section "Section 3: Enable Repositories"

    # dnf-plugins-core is required for dnf config-manager and dnf copr
    if ! pkg_installed dnf-plugins-core; then
        log_info "Installing dnf-plugins-core..."
        sudo dnf install -y dnf-plugins-core 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "dnf-plugins-core already installed"
    fi

    # RPM Fusion Free
    if ! pkg_installed rpmfusion-free-release; then
        log_info "Enabling RPM Fusion Free..."
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
            2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "RPM Fusion Free already enabled"
    fi

    # RPM Fusion Nonfree
    if ! pkg_installed rpmfusion-nonfree-release; then
        log_info "Enabling RPM Fusion Nonfree..."
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
            2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "RPM Fusion Nonfree already enabled"
    fi

    # Google Chrome
    if [[ ! -f /etc/yum.repos.d/google-chrome.repo ]]; then
        log_info "Adding Google Chrome repository..."
        sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub
        sudo tee /etc/yum.repos.d/google-chrome.repo > /dev/null <<'EOF'
[google-chrome]
name=Google Chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
    else
        log_warn "Google Chrome repo already configured"
    fi

    # Docker CE
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
        log_info "Adding Docker CE repository..."
        sudo dnf config-manager addrepo \
            --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
            2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "Docker CE repo already configured"
    fi

    # PyCharm COPR
    if ! sudo dnf copr list --enabled 2>/dev/null | grep -q "phracek/PyCharm"; then
        log_info "Enabling PyCharm COPR..."
        sudo dnf copr enable -y phracek/PyCharm 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "PyCharm COPR already enabled"
    fi
}

# ─── Section 4: System Upgrade ───────────────────────────────────────────────

system_upgrade() {
    log_section "Section 4: System Upgrade"
    log_info "Running dnf upgrade (this may take a while)..."
    sudo dnf upgrade -y 2>&1 | tee -a "$LOG_FILE"
}

# ─── Section 5: Package Installation ─────────────────────────────────────────

install_packages() {
    log_section "Section 5: Package Installation"

    local SYSTEM_TOOLS=(
        zsh git gh curl wget unzip tar bat fzf htop
    )

    local DEV_TOOLS=(
        docker-ce docker-ce-cli containerd.io
        podman
        python3 python3-pip
        java-21-openjdk
    )

    local MEDIA=(
        vlc
        ffmpeg
        gstreamer1-plugins-good
        gstreamer1-plugins-bad-free
        gstreamer1-plugins-ugly
        gstreamer1-libav
        mozilla-openh264
        gamemode
    )

    local APPS=(
        google-chrome-stable
        ghostty
        libreoffice
        steam
        papirus-icon-theme
        gnome-shell-extension-dash-to-dock
        gnome-shell-extension-appindicator
        gnome-shell-extension-manager
    )

    for pkg in "${SYSTEM_TOOLS[@]}" "${DEV_TOOLS[@]}" "${MEDIA[@]}" "${APPS[@]}"; do
        dnf_install "$pkg"
    done
}

# ─── Section 6: NVIDIA Drivers ───────────────────────────────────────────────

install_nvidia() {
    log_section "Section 6: NVIDIA Drivers"

    if pkg_installed akmod-nvidia; then
        log_warn "akmod-nvidia already installed, skipping"
        return
    fi

    log_info "Installing NVIDIA drivers..."
    sudo dnf install -y \
        akmod-nvidia \
        xorg-x11-drv-nvidia-cuda \
        nvidia-vaapi-driver \
        nvidia-settings \
        2>&1 | tee -a "$LOG_FILE"

    echo ""
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "  NVIDIA: kernel module will build on first boot."
    log_warn "  Do NOT skip the reboot at the end of this script."
    log_warn "  If Secure Boot is enabled, you must enroll the MOK key."
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Section 7: Fonts ─────────────────────────────────────────────────────────

install_fonts() {
    log_section "Section 7: Fonts (MesloLGS NF)"

    local FONT_DIR="$HOME/.local/share/fonts"
    local FONT_CHECK="$FONT_DIR/MesloLGS NF Regular.ttf"

    if [[ -f "$FONT_CHECK" ]]; then
        log_warn "MesloLGS NF already installed, skipping"
        return
    fi

    mkdir -p "$FONT_DIR"
    local BASE_URL="https://github.com/romkatv/powerlevel10k-media/raw/master"
    local FONTS=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )

    for font in "${FONTS[@]}"; do
        log_info "Downloading $font..."
        curl -fLo "$FONT_DIR/$font" "${BASE_URL}/${font// /%20}"
    done

    fc-cache -fv "$FONT_DIR" 2>&1 | tee -a "$LOG_FILE"
    log_info "MesloLGS NF installed and font cache updated."
}

# ─── Section 8: Oh My Zsh + Powerlevel10k + Plugins ─────────────────────────

install_shell_extras() {
    log_section "Section 8: Oh My Zsh + Powerlevel10k + Plugins"

    # Oh My Zsh
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_warn "Oh My Zsh already installed"
    else
        log_info "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            2>&1 | tee -a "$LOG_FILE"
    fi

    local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # Powerlevel10k
    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        log_info "Installing Powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k" 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "Powerlevel10k already installed"
    fi

    # External plugins
    declare -A PLUGINS=(
        [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
        [zsh-completions]="https://github.com/zsh-users/zsh-completions"
        [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting"
    )

    for plugin in "${!PLUGINS[@]}"; do
        if [[ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]]; then
            log_info "Installing plugin: $plugin..."
            git clone --depth=1 "${PLUGINS[$plugin]}" "$ZSH_CUSTOM/plugins/$plugin" \
                2>&1 | tee -a "$LOG_FILE"
        else
            log_warn "Plugin $plugin already installed"
        fi
    done
}

# ─── Section 9: fnm + Node.js LTS ────────────────────────────────────────────

install_node() {
    log_section "Section 9: fnm + Node.js LTS"

    local FNM_BIN="$HOME/.local/bin/fnm"
    mkdir -p "$HOME/.local/bin"

    if [[ -x "$FNM_BIN" ]]; then
        log_warn "fnm already installed"
    else
        log_info "Installing fnm..."
        curl -fsSL https://fnm.vercel.app/install | bash \
            --install-dir "$HOME/.local/bin" --skip-shell \
            2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -x "$FNM_BIN" ]]; then
        log_info "Installing Node.js LTS via fnm..."
        "$FNM_BIN" install --lts 2>&1 | tee -a "$LOG_FILE"
        "$FNM_BIN" default lts-latest 2>&1 | tee -a "$LOG_FILE"
        log_info "Node.js LTS installed and set as default."
    else
        log_error "fnm binary not found at $FNM_BIN after install."
        return 1
    fi

    # Resolve npm from fnm-managed Node
    local NPM_BIN
    NPM_BIN="$("$FNM_BIN" exec --using=lts-latest which npm 2>/dev/null)"

    if [[ -z "$NPM_BIN" ]]; then
        log_error "npm not found via fnm; skipping global npm packages."
        return 1
    fi

    log_info "Installing Claude Code..."
    if "$NPM_BIN" list -g @anthropic-ai/claude-code &>/dev/null; then
        log_warn "Claude Code already installed"
    else
        "$NPM_BIN" install -g @anthropic-ai/claude-code 2>&1 | tee -a "$LOG_FILE"
    fi

    log_info "Installing pi coding agent..."
    if "$NPM_BIN" list -g @earendil-works/pi-coding-agent &>/dev/null; then
        log_warn "pi already installed"
    else
        "$NPM_BIN" install -g @earendil-works/pi-coding-agent 2>&1 | tee -a "$LOG_FILE"
    fi

    log_info "Installing pnpm..."
    if "$NPM_BIN" list -g pnpm &>/dev/null; then
        log_warn "pnpm already installed"
    else
        "$NPM_BIN" install -g pnpm 2>&1 | tee -a "$LOG_FILE"
    fi
}

# ─── Section 9b: SSH Key Setup ───────────────────────────────────────────────

setup_ssh() {
    log_section "Section 9b: SSH Key Setup"

    local SSH_KEY="$HOME/.ssh/id_ed25519"

    if [[ -f "$SSH_KEY" ]]; then
        log_warn "SSH key already exists at $SSH_KEY, skipping"
        return
    fi

    local EMAIL
    EMAIL="$(git config --global user.email 2>/dev/null || echo "")"
    if [[ -z "$EMAIL" ]]; then
        read -rp "Email for SSH key: " EMAIL
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY" -N ""
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY"
    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

    echo ""
    log_info "SSH key generated. Add this public key to GitHub:"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
    log_warn "Go to: https://github.com/settings/ssh/new"
    read -rp "Press Enter once you've added the key to GitHub..."
    ssh -T git@github.com 2>&1 | tee -a "$LOG_FILE" || true
}

# ─── Section 10: Docker Post-install ─────────────────────────────────────────

docker_postinstall() {
    log_section "Section 10: Docker Post-install"

    log_info "Enabling Docker service..."
    sudo systemctl enable --now docker containerd 2>&1 | tee -a "$LOG_FILE"

    if groups "$USER" | grep -q docker; then
        log_warn "User $USER already in docker group"
    else
        log_info "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
        log_warn "Group membership active after reboot."
    fi
}

# ─── Section 11: GNOME Configuration ─────────────────────────────────────────

configure_gnome() {
    log_section "Section 11: GNOME Configuration"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session detected (running via SSH?). Skipping GNOME settings."
        return
    fi

    log_info "Setting dark mode..."
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'

    log_info "Setting Papirus icon theme..."
    gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'

    log_info "Setting default browser to Google Chrome..."
    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || \
        log_warn "Could not set default browser (Chrome may not be installed yet)"

    log_info "Setting VLC as default video player..."
    for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
        xdg-mime default vlc.desktop "$mime"
    done

    log_info "Enabling AppIndicator (system tray) extension..."
    gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null || \
        log_warn "Could not enable AppIndicator extension (will activate after logout/login)"

    log_warn "GNOME extensions require logout/login to activate."
}

# ─── Section 12: Dotfiles ────────────────────────────────────────────────────

setup_dotfiles() {
    log_section "Section 12: Dotfiles"

    local FILES=(
        ".zshrc"
        ".p10k.zsh"
        ".config/ghostty/config"
    )

    mkdir -p "$BACKUP_DIR"

    for file in "${FILES[@]}"; do
        local target="$HOME/$file"
        local source="$DOTFILES_DIR/$file"

        if [[ ! -f "$source" ]]; then
            log_warn "Not found in dotfiles repo: $file — skipping"
            continue
        fi

        if [[ -e "$target" && ! -L "$target" ]]; then
            mkdir -p "$BACKUP_DIR/$(dirname "$file")"
            mv "$target" "$BACKUP_DIR/$file"
            log_warn "Backed up $target → $BACKUP_DIR/$file"
        fi

        mkdir -p "$(dirname "$target")"
        ln -sf "$source" "$target"
        log_info "Symlinked ~/$file → $source"
    done
}

# ─── Section 13: Default Shell ───────────────────────────────────────────────

set_default_shell() {
    log_section "Section 13: Default Shell"

    local ZSH_PATH
    ZSH_PATH="$(command -v zsh)"

    if [[ "$SHELL" == "$ZSH_PATH" ]]; then
        log_warn "zsh is already the default shell"
        return
    fi

    grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells > /dev/null
    chsh -s "$ZSH_PATH" "$USER"
    log_info "Default shell changed to zsh. Effective after next login."
}

# ─── Section 14: Reboot Prompt ───────────────────────────────────────────────

reboot_prompt() {
    log_section "Setup Complete"

    echo ""
    log_warn "The following require a reboot to take effect:"
    log_warn "  • NVIDIA akmod kernel module build"
    log_warn "  • Docker group membership"
    log_warn "  • Default shell change to zsh"
    log_warn "  • GNOME extensions activation"
    echo ""
    read -rp "Reboot now? [y/N]: " answer
    if [[ "${answer,,}" == "y" ]]; then
        log_info "Rebooting..."
        sudo reboot
    else
        log_info "Reboot skipped. Please reboot manually when ready."
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Fedora setup started at $(date)"
    echo ""

    preflight_checks
    configure_git
    enable_repos
    system_upgrade
    install_packages
    install_nvidia
    install_fonts
    install_shell_extras
    install_node
    setup_ssh
    docker_postinstall
    configure_gnome
    setup_dotfiles
    set_default_shell
    reboot_prompt

    log_info "Setup completed at $(date)"
}

main "$@"
