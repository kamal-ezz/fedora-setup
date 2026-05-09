#!/usr/bin/env bash
# Fedora post-install setup script
# Run as your regular user (not root), from a desktop session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.fedora-setup.log"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"
START_TIME=$(date +%s)

declare -a SUMMARY=()

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/checks.sh"

summary_ok()   { SUMMARY+=("  ${GREEN}✓${NC}  $*"); }
summary_skip() { SUMMARY+=("  ${YELLOW}→${NC}  $*"); }
summary_fail() { SUMMARY+=("  ${RED}✗${NC}  $*"); }

# ─── Section 2: Git Config ────────────────────────────────────────────────────

configure_git() {
    log_section "Section 2: Git Configuration"

    if [[ -f "$HOME/.gitconfig" ]]; then
        log_warn "~/.gitconfig already exists, skipping"
        summary_skip "Git config (already exists)"
        return
    fi

    read -rp "Git name:  " GIT_NAME
    read -rp "Git email: " GIT_EMAIL
    git config --global user.name  "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    log_info "Git config written."
    summary_ok "Git config"
}

# ─── Section 3: Repositories ─────────────────────────────────────────────────

enable_repos() {
    log_section "Section 3: Enable Repositories"

    # dnf-plugins-core is required for dnf config-manager and dnf copr
    dnf_install_bulk dnf-plugins-core

    # RPM Fusion Free
    if ! pkg_installed rpmfusion-free-release; then
        log_info "Enabling RPM Fusion Free..."
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    else
        log_warn "RPM Fusion Free already enabled"
    fi

    # RPM Fusion Nonfree
    if ! pkg_installed rpmfusion-nonfree-release; then
        log_info "Enabling RPM Fusion Nonfree..."
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
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
            --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    else
        log_warn "Docker CE repo already configured"
    fi

    # VS Code
    if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
        log_info "Adding VS Code repository..."
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    else
        log_warn "VS Code repo already configured"
    fi

    # PyCharm COPR
    if ! sudo dnf copr list --enabled 2>/dev/null | grep -q "phracek/PyCharm"; then
        log_info "Enabling PyCharm COPR..."
        sudo dnf copr enable -y phracek/PyCharm
    else
        log_warn "PyCharm COPR already enabled"
    fi

    summary_ok "Repositories"
}

# ─── Section 4: System Upgrade ───────────────────────────────────────────────

system_upgrade() {
    log_section "Section 4: System Upgrade"
    log_info "Running dnf upgrade (this may take a while)..."
    sudo dnf upgrade -y
    summary_ok "System upgrade"
}

# ─── Section 5: Package Installation ─────────────────────────────────────────

install_packages() {
    log_section "Section 5: Package Installation"

    dnf_install_bulk \
        `# System tools` \
        zsh git gh curl wget unzip tar bat fzf htop cabextract \
        `# Dev tools` \
        docker-ce docker-ce-cli containerd.io podman \
        python3 python3-pip java-21-openjdk \
        `# Media & codecs` \
        vlc ffmpeg \
        gstreamer1-plugins-good gstreamer1-plugins-bad-free \
        gstreamer1-plugins-ugly gstreamer1-libav \
        mozilla-openh264 gamemode \
        `# Apps` \
        google-chrome-stable ghostty libreoffice steam code \
        `# GNOME` \
        papirus-icon-theme \
        gnome-shell-extension-dash-to-dock \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-manager \
        `# Fonts` \
        google-noto-sans-arabic-fonts \
        google-noto-naskh-arabic-fonts \
        amiri-fonts \
        `# Bluetooth` \
        bluez

    summary_ok "Packages"
}

# ─── Section 5b: Microsoft Fonts ─────────────────────────────────────────────

install_ms_fonts() {
    log_section "Section 5b: Microsoft Fonts"

    if rpm -q msttcore-fonts-installer &>/dev/null; then
        log_warn "Microsoft fonts already installed, skipping"
        summary_skip "Microsoft fonts (already installed)"
        return
    fi

    local TMP_RPM="/tmp/msttcore-fonts-installer.rpm"
    log_info "Downloading Microsoft fonts installer..."
    curl -fLo "$TMP_RPM" \
        "https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm"
    sudo dnf install -y "$TMP_RPM"
    rm -f "$TMP_RPM"
    log_info "Microsoft fonts installed."
    summary_ok "Microsoft fonts"
}

# ─── Section 5c: yt-dlp and Neovim ───────────────────────────────────────────

install_extra_tools() {
    log_section "Section 5c: yt-dlp and Neovim"

    mkdir -p "$HOME/.local/bin"

    # yt-dlp
    if cmd_exists yt-dlp; then
        log_warn "yt-dlp already installed"
        summary_skip "yt-dlp (already installed)"
    else
        log_info "Installing yt-dlp..."
        curl -fLo "$HOME/.local/bin/yt-dlp" \
            https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
        chmod +x "$HOME/.local/bin/yt-dlp"
        log_info "yt-dlp installed."
        summary_ok "yt-dlp"
    fi

    # Neovim (tarball → /opt/nvim)
    if cmd_exists nvim; then
        log_warn "Neovim already installed"
        summary_skip "Neovim (already installed)"
    else
        log_info "Installing Neovim..."
        local NVIM_TMP="/tmp/nvim-linux-x86_64.tar.gz"
        curl -fLo "$NVIM_TMP" \
            https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
        sudo tar -C /opt -xzf "$NVIM_TMP"
        sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
        rm -f "$NVIM_TMP"
        log_info "Neovim installed."
        summary_ok "Neovim"
    fi
}

# ─── Section 6: NVIDIA Drivers ───────────────────────────────────────────────

install_nvidia() {
    log_section "Section 6: NVIDIA Drivers"

    if pkg_installed akmod-nvidia; then
        log_warn "akmod-nvidia already installed, skipping"
        summary_skip "NVIDIA drivers (already installed)"
        return
    fi

    log_info "Installing NVIDIA drivers..."
    sudo dnf install -y \
        akmod-nvidia \
        xorg-x11-drv-nvidia-cuda \
        nvidia-vaapi-driver \
        nvidia-settings

    echo ""
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "  NVIDIA: kernel module will build on first boot."
    log_warn "  Do NOT skip the reboot at the end of this script."
    log_warn "  If Secure Boot is enabled, you must enroll the MOK key."
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    summary_ok "NVIDIA drivers (reboot required)"
}

# ─── Section 7: Fonts ─────────────────────────────────────────────────────────

install_fonts() {
    log_section "Section 7: Fonts (MesloLGS NF)"

    local FONT_DIR="$HOME/.local/share/fonts"
    local FONT_CHECK="$FONT_DIR/MesloLGS NF Regular.ttf"

    if [[ -f "$FONT_CHECK" ]]; then
        log_warn "MesloLGS NF already installed, skipping"
        summary_skip "MesloLGS NF fonts (already installed)"
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

    fc-cache -fv "$FONT_DIR"
    log_info "MesloLGS NF installed and font cache updated."
    summary_ok "MesloLGS NF fonts"
}

# ─── Section 8: Oh My Zsh + Powerlevel10k + Plugins ─────────────────────────

install_shell_extras() {
    log_section "Section 8: Oh My Zsh + Powerlevel10k + Plugins"

    # Oh My Zsh
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_warn "Oh My Zsh already installed"
    else
        log_info "Installing Oh My Zsh..."
        local OMZ_SCRIPT="/tmp/omz-install.sh"
        curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
            -o "$OMZ_SCRIPT"
        RUNZSH=no CHSH=no bash "$OMZ_SCRIPT"
        rm -f "$OMZ_SCRIPT"
    fi

    local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # Powerlevel10k
    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        log_info "Installing Powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k"
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
            git clone --depth=1 "${PLUGINS[$plugin]}" "$ZSH_CUSTOM/plugins/$plugin"
        else
            log_warn "Plugin $plugin already installed"
        fi
    done

    summary_ok "Oh My Zsh + Powerlevel10k + plugins"
}

# ─── Section 9: fnm + Node.js LTS + global packages ─────────────────────────

install_node() {
    log_section "Section 9: fnm + Node.js LTS"

    local FNM_BIN="$HOME/.local/bin/fnm"
    mkdir -p "$HOME/.local/bin"

    if [[ -x "$FNM_BIN" ]]; then
        log_warn "fnm already installed"
    else
        log_info "Installing fnm..."
        local FNM_SCRIPT="/tmp/fnm-install.sh"
        curl -fsSL https://fnm.vercel.app/install -o "$FNM_SCRIPT"
        bash "$FNM_SCRIPT" --install-dir "$HOME/.local/bin" --skip-shell
        rm -f "$FNM_SCRIPT"
    fi

    if [[ ! -x "$FNM_BIN" ]]; then
        log_error "fnm binary not found at $FNM_BIN after install."
        summary_fail "fnm + Node.js"
        return 1
    fi

    log_info "Installing Node.js LTS via fnm..."
    "$FNM_BIN" install --lts
    "$FNM_BIN" default lts-latest
    log_info "Node.js LTS installed and set as default."

    local NPM_BIN
    NPM_BIN="$("$FNM_BIN" exec --using=lts-latest which npm 2>/dev/null)"

    if [[ -z "$NPM_BIN" ]]; then
        log_error "npm not found via fnm; skipping global npm packages."
        summary_fail "npm global packages"
        return 1
    fi

    local NPM_GLOBALS=(
        "@anthropic-ai/claude-code"
        "@earendil-works/pi-coding-agent"
        "pnpm"
    )

    for pkg in "${NPM_GLOBALS[@]}"; do
        if "$NPM_BIN" list -g "$pkg" &>/dev/null; then
            log_warn "$pkg already installed"
        else
            log_info "Installing $pkg..."
            "$NPM_BIN" install -g "$pkg"
        fi
    done

    summary_ok "fnm + Node.js LTS + global packages"
}

# ─── Section 10: SSH Key Setup ────────────────────────────────────────────────

setup_ssh() {
    log_section "Section 10: SSH Key Setup"

    local SSH_KEY="$HOME/.ssh/id_ed25519"

    if [[ -f "$SSH_KEY" ]]; then
        log_warn "SSH key already exists at $SSH_KEY, skipping"
        summary_skip "SSH key (already exists)"
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
    ssh -T git@github.com 2>&1 || true
    summary_ok "SSH key"
}

# ─── Section 11: Docker + Bluetooth ──────────────────────────────────────────

setup_services() {
    log_section "Section 11: Docker + Bluetooth"

    # Docker
    log_info "Enabling Docker service..."
    sudo systemctl enable --now docker containerd

    if groups "$USER" | grep -q docker; then
        log_warn "User $USER already in docker group"
    else
        log_info "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
        log_warn "Docker group membership active after reboot."
    fi

    # Bluetooth
    dnf_install_bulk bluez

    if systemctl is-active --quiet bluetooth; then
        log_warn "Bluetooth service already running"
    else
        log_info "Bluetooth service not running, enabling and starting..."
        sudo systemctl enable --now bluetooth
    fi

    summary_ok "Docker + Bluetooth services"
}

# ─── Section 12: GNOME Configuration ─────────────────────────────────────────

configure_gnome() {
    log_section "Section 12: GNOME Configuration"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session detected (running via SSH?). Skipping GNOME settings."
        summary_skip "GNOME config (no D-Bus session)"
        return
    fi

    gsettings set org.gnome.desktop.interface color-scheme   'prefer-dark'
    gsettings set org.gnome.desktop.interface icon-theme     'Papirus-Dark'
    gsettings set org.gnome.desktop.input-sources sources    "[('xkb', 'us'), ('xkb', 'ara')]"
    gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas'

    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || \
        log_warn "Could not set default browser"

    for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
        xdg-mime default vlc.desktop "$mime"
    done

    sudo hostnamectl set-hostname fedora

    powerprofilesctl set power-saver 2>/dev/null || \
        log_warn "Could not set power profile"

    gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || \
        log_warn "Dash to Dock will activate after logout/login"

    gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null || \
        log_warn "AppIndicator will activate after logout/login"

    log_warn "GNOME extensions require logout/login to activate."
    summary_ok "GNOME configuration"
}

# ─── Section 13: Dotfiles ────────────────────────────────────────────────────

setup_dotfiles() {
    log_section "Section 13: Dotfiles"

    local FILES=(
        ".zshrc"
        ".p10k.zsh"
        ".config/ghostty/config"
        ".config/fontconfig/fonts.conf"
    )

    for file in "${FILES[@]}"; do
        local target="$HOME/$file"
        local source="$DOTFILES_DIR/$file"

        if [[ ! -f "$source" ]]; then
            log_warn "Not found in dotfiles: $file — skipping"
            continue
        fi

        if [[ -e "$target" && ! -L "$target" ]]; then
            mkdir -p "$BACKUP_DIR/$(dirname "$file")"
            mv "$target" "$BACKUP_DIR/$file"
            log_warn "Backed up $target → $BACKUP_DIR/$file"
        fi

        mkdir -p "$(dirname "$target")"
        ln -sf "$source" "$target"
        log_info "Symlinked ~/$file"
    done

    summary_ok "Dotfiles"
}

# ─── Section 14: Default Shell ───────────────────────────────────────────────

set_default_shell() {
    log_section "Section 14: Default Shell"

    local ZSH_PATH
    ZSH_PATH="$(command -v zsh)"

    if [[ "$SHELL" == "$ZSH_PATH" ]]; then
        log_warn "zsh is already the default shell"
        summary_skip "Default shell (already zsh)"
        return
    fi

    grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells > /dev/null
    chsh -s "$ZSH_PATH" "$USER"
    log_info "Default shell changed to zsh."
    summary_ok "Default shell → zsh"
}

# ─── Summary + Reboot ────────────────────────────────────────────────────────

print_summary() {
    log_section "Summary"

    for line in "${SUMMARY[@]}"; do
        echo -e "$line"
    done

    echo ""
    local END_TIME ELAPSED
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log_info "Completed in $(printf '%dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))"
}

reboot_prompt() {
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
    # Redirect stdout and stderr independently through tee so both
    # appear on terminal and are written to the log file.
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)

    log_info "Fedora setup started at $(date)"
    echo ""

    preflight_checks
    configure_git
    enable_repos
    system_upgrade
    install_packages
    install_ms_fonts
    install_extra_tools
    install_nvidia
    install_fonts
    install_shell_extras
    install_node
    setup_ssh
    setup_services
    configure_gnome
    setup_dotfiles
    set_default_shell
    print_summary
    reboot_prompt

    log_info "Setup completed at $(date)"
}

main "$@"
