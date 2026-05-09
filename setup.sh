#!/usr/bin/env bash
# Fedora post-install setup script
# Run as your regular user (not root), from a desktop session.
#
# Usage:
#   bash setup.sh                        # run all sections
#   bash setup.sh --only gnome dotfiles  # run only these sections
#   bash setup.sh --skip nvidia snapper  # run all except these
#   bash setup.sh --list                 # list available sections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.fedora-setup.log"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"
START_TIME=$(date +%s)

declare -a SUMMARY=()
declare -a ONLY_SECTIONS=()
declare -a SKIP_SECTIONS=()

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/checks.sh"

summary_ok()   { SUMMARY+=("  ${GREEN}✓${NC}  $*"); }
summary_skip() { SUMMARY+=("  ${YELLOW}→${NC}  $*"); }
summary_fail() { SUMMARY+=("  ${RED}✗${NC}  $*"); }

# ─── Argument parsing ─────────────────────────────────────────────────────────

list_sections() {
    echo "Available sections:"
    echo "  git          Git configuration"
    echo "  dnf          DNF tuning (parallel downloads, fastest mirror)"
    echo "  repos        Enable repositories (RPM Fusion, Chrome, Docker, VS Code, PyCharm)"
    echo "  upgrade      System upgrade"
    echo "  packages     Package installation"
    echo "  ms-fonts     Microsoft fonts"
    echo "  extra-tools  yt-dlp, Neovim, opencode"
    echo "  ghostty      Build Ghostty from source (zvm + Zig)"
    echo "  flatpak      Flatpak + Flathub + Spotify"
    echo "  nvidia       NVIDIA drivers"
    echo "  fonts        MesloLGS NF fonts"
    echo "  shell        Oh My Zsh + Powerlevel10k + plugins"
    echo "  node         fnm + Node.js LTS + npm globals"
    echo "  ssh          SSH key setup"
    echo "  services     Docker + Bluetooth + Firewall"
    echo "  virt         Virtualization (KVM/QEMU)"
    echo "  snapper      Btrfs snapshots (skipped if not Btrfs)"
    echo "  vscode       VS Code extensions + Catppuccin Mocha theme"
    echo "  gnome        GNOME configuration"
    echo "  dotfiles     Dotfiles symlinks"
    echo "  shell-default  Set zsh as default shell"
    echo ""
    echo "Examples:"
    echo "  bash setup.sh --only gnome dotfiles"
    echo "  bash setup.sh --skip nvidia snapper virt"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                shift
                while [[ $# -gt 0 && "${1:-}" != --* ]]; do
                    ONLY_SECTIONS+=("$1"); shift
                done
                ;;
            --skip)
                shift
                while [[ $# -gt 0 && "${1:-}" != --* ]]; do
                    SKIP_SECTIONS+=("$1"); shift
                done
                ;;
            --list)
                list_sections; exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                echo "Use --list to see available sections." >&2
                exit 1
                ;;
        esac
    done
}

should_run() {
    local section="$1"
    if [[ ${#ONLY_SECTIONS[@]} -gt 0 ]]; then
        for s in "${ONLY_SECTIONS[@]}"; do
            [[ "$s" == "$section" ]] && return 0
        done
        return 1
    fi
    for s in "${SKIP_SECTIONS[@]}"; do
        [[ "$s" == "$section" ]] && return 1
    done
    return 0
}

run_section() {
    local slug="$1"
    local fn="$2"
    if should_run "$slug"; then
        "$fn"
    else
        log_warn "Skipping: $slug"
    fi
}

# ─── Section 1: Git Config ────────────────────────────────────────────────────

configure_git() {
    log_section "Section 1: Git Configuration"

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

# ─── Section 2: DNF Configuration ────────────────────────────────────────────

configure_dnf() {
    log_section "Section 2: DNF Configuration"

    local DNF_CONF="/etc/dnf/dnf.conf"
    local SETTINGS=(
        "max_parallel_downloads=10"
        "fastestmirror=True"
        "defaultyes=True"
    )

    for setting in "${SETTINGS[@]}"; do
        local key="${setting%%=*}"
        if grep -q "^${key}=" "$DNF_CONF" 2>/dev/null; then
            log_warn "$key already set in dnf.conf"
        else
            echo "$setting" | sudo tee -a "$DNF_CONF" > /dev/null
            log_info "Set $setting"
        fi
    done

    summary_ok "DNF configuration"
}

# ─── Section 3: Repositories ─────────────────────────────────────────────────

enable_repos() {
    log_section "Section 3: Enable Repositories"

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

    # ProtonVPN
    if [[ ! -f /etc/yum.repos.d/protonvpn-stable.repo ]]; then
        log_info "Adding ProtonVPN repository..."
        sudo dnf config-manager addrepo \
            --from-repofile="https://repo.protonvpn.com/fedora-$(rpm -E %fedora)-stable/protonvpn-stable.repo"
    else
        log_warn "ProtonVPN repo already configured"
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
        golang gcc gcc-c++ make cmake clang \
        `# Media & codecs` \
        vlc ffmpeg \
        gstreamer1-plugins-good gstreamer1-plugins-bad-free \
        gstreamer1-plugins-ugly gstreamer1-libav \
        mozilla-openh264 \
        `# Gaming` \
        gamemode mangohud lutris goverlay wine \
        `# Apps` \
        google-chrome-stable libreoffice steam code \
        protonvpn-cli \
        `# GNOME` \
        papirus-icon-theme gnome-tweaks \
        gnome-shell-extension-dash-to-dock \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-manager \
        `# Qt theming` \
        qt5ct qt6ct \
        `# Fonts` \
        google-noto-sans-arabic-fonts \
        google-noto-naskh-arabic-fonts \
        amiri-fonts \
        `# Bluetooth` \
        bluez

    # Swap ffmpeg-free → full ffmpeg for complete codec support
    if rpm -q ffmpeg-free &>/dev/null && ! rpm -q ffmpeg &>/dev/null; then
        log_info "Swapping ffmpeg-free → ffmpeg for full codec support..."
        sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
    else
        log_warn "ffmpeg already correct"
    fi

    summary_ok "Packages"
}

# ─── Section 6: Microsoft Fonts ──────────────────────────────────────────────

install_ms_fonts() {
    log_section "Section 6: Microsoft Fonts"

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

# ─── Section 7: Extra Tools (yt-dlp, Neovim) ─────────────────────────────────

install_extra_tools() {
    log_section "Section 7: Extra Tools (yt-dlp, Neovim)"

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
        summary_ok "Neovim"
    fi

    # opencode desktop app (RPM from GitHub releases)
    if pkg_installed opencode; then
        log_warn "opencode already installed"
        summary_skip "opencode (already installed)"
    else
        log_info "Installing opencode desktop..."
        local OC_RPM_URL
        OC_RPM_URL=$(curl -fsSL https://api.github.com/repos/sst/opencode/releases/latest \
            | grep -o '"browser_download_url": *"[^"]*\.rpm"' \
            | grep -o 'https://[^"]*' \
            | head -1)
        if [[ -z "$OC_RPM_URL" ]]; then
            log_warn "Could not determine opencode RPM download URL, skipping"
            summary_fail "opencode"
        else
            local OC_RPM="/tmp/opencode.rpm"
            curl -fLo "$OC_RPM" "$OC_RPM_URL"
            sudo dnf install -y "$OC_RPM"
            rm -f "$OC_RPM"
            summary_ok "opencode desktop"
        fi
    fi
}

# ─── Section 8: Ghostty (build from source) ──────────────────────────────────

install_ghostty() {
    log_section "Section 8: Ghostty (build from source)"

    if cmd_exists ghostty; then
        log_warn "Ghostty already installed, skipping"
        summary_skip "Ghostty (already installed)"
        return
    fi

    # Build dependencies
    dnf_install_bulk gtk4-devel gtk4-layer-shell-devel libadwaita-devel gettext

    # zvm (Zig Version Manager)
    local ZVM_BIN="$HOME/.zvm/self/zvm"
    if [[ -x "$ZVM_BIN" ]]; then
        log_warn "zvm already installed"
    else
        log_info "Installing zvm..."
        local ZVM_SCRIPT="/tmp/zvm-install.sh"
        curl -fsSL https://www.zvm.app/install.sh -o "$ZVM_SCRIPT"
        bash "$ZVM_SCRIPT"
        rm -f "$ZVM_SCRIPT"
    fi

    export PATH="$HOME/.zvm/bin:$HOME/.zvm/self:$PATH"

    # Latest stable Ghostty tag
    local GHOSTTY_TAG
    GHOSTTY_TAG=$(curl -fsSL https://api.github.com/repos/ghostty-org/ghostty/releases/latest \
        | grep '"tag_name"' | grep -o '"[^"]*"' | tail -1 | tr -d '"')
    log_info "Cloning Ghostty $GHOSTTY_TAG..."

    local GHOSTTY_SRC="/tmp/ghostty-src"
    rm -rf "$GHOSTTY_SRC"
    git clone --depth=1 --branch "$GHOSTTY_TAG" \
        https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SRC"

    # Install the exact Zig version the release requires
    local ZIG_VERSION
    ZIG_VERSION=$(cat "$GHOSTTY_SRC/.zigversion")
    log_info "Installing Zig $ZIG_VERSION via zvm..."
    zvm install "$ZIG_VERSION"
    zvm use "$ZIG_VERSION"

    log_info "Building Ghostty (this will take a few minutes)..."
    (cd "$GHOSTTY_SRC" && zig build -Doptimize=ReleaseFast --prefix "$HOME/.local")

    rm -rf "$GHOSTTY_SRC"
    summary_ok "Ghostty $GHOSTTY_TAG (built from source)"
}

# ─── Section 9: Flatpak + Flathub ────────────────────────────────────────────

setup_flatpak() {
    log_section "Section 9: Flatpak + Flathub"

    dnf_install_bulk flatpak gnome-software-plugin-flatpak

    if flatpak remotes 2>/dev/null | grep -q flathub; then
        log_warn "Flathub already configured"
        summary_skip "Flathub (already configured)"
    else
        log_info "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo
        summary_ok "Flathub"
    fi

    if flatpak list 2>/dev/null | grep -q "com.spotify.Client"; then
        log_warn "Spotify already installed"
    else
        log_info "Installing Spotify..."
        flatpak install -y flathub com.spotify.Client
        summary_ok "Spotify"
    fi
}

# ─── Section 10: NVIDIA Drivers ───────────────────────────────────────────────

install_nvidia() {
    log_section "Section 10: NVIDIA Drivers"

    if pkg_installed akmod-nvidia; then
        log_warn "akmod-nvidia already installed, skipping"
        summary_skip "NVIDIA drivers (already installed)"
        return
    fi

    log_info "Installing NVIDIA drivers..."
    sudo dnf install -y \
        akmod-nvidia \
        xorg-x11-drv-nvidia-cuda \
        xorg-x11-drv-nvidia-libs.i686 \
        nvidia-vaapi-driver \
        nvidia-settings

    # Enable DRM kernel mode setting — required for GNOME Wayland with NVIDIA
    if ! sudo grubby --info=ALL 2>/dev/null | grep -q "nvidia-drm.modeset=1"; then
        log_info "Enabling nvidia-drm.modeset=1 for Wayland..."
        sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=1"
    else
        log_warn "nvidia-drm.modeset=1 already set"
    fi

    echo ""
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "  NVIDIA: kernel module will build on first boot."
    log_warn "  Do NOT skip the reboot at the end of this script."
    log_warn "  If Secure Boot is enabled, you must enroll the MOK key."
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    summary_ok "NVIDIA drivers (reboot required)"
}

# ─── Section 11: Fonts ───────────────────────────────────────────────────────

install_fonts() {
    log_section "Section 11: Fonts (MesloLGS NF)"

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
    summary_ok "MesloLGS NF fonts"
}

# ─── Section 12: Oh My Zsh + Powerlevel10k + Plugins ─────────────────────────

install_shell_extras() {
    log_section "Section 12: Oh My Zsh + Powerlevel10k + Plugins"

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

    if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        log_info "Installing Powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k"
    else
        log_warn "Powerlevel10k already installed"
    fi

    local PLUGINS=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-completions|https://github.com/zsh-users/zsh-completions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting"
    )

    for entry in "${PLUGINS[@]}"; do
        local plugin="${entry%%|*}"
        local url="${entry#*|}"
        if [[ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]]; then
            log_info "Installing plugin: $plugin..."
            git clone --depth=1 "$url" "$ZSH_CUSTOM/plugins/$plugin"
        else
            log_warn "Plugin $plugin already installed"
        fi
    done

    summary_ok "Oh My Zsh + Powerlevel10k + plugins"
}

# ─── Section 13: fnm + Node.js LTS + global packages ─────────────────────────

install_node() {
    log_section "Section 13: fnm + Node.js LTS"

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

# ─── Section 14: SSH Key Setup ────────────────────────────────────────────────

setup_ssh() {
    log_section "Section 14: SSH Key Setup"

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

# ─── Section 15: Services (Docker, Bluetooth, Firewall) ──────────────────────

setup_services() {
    log_section "Section 15: Services (Docker, Bluetooth, Firewall)"

    # Docker
    log_info "Enabling Docker service..."
    sudo systemctl enable --now docker containerd

    if groups "$USER" | grep -q docker; then
        log_warn "User $USER already in docker group"
    else
        sudo usermod -aG docker "$USER"
        log_warn "Docker group membership active after reboot."
    fi

    # Bluetooth
    if systemctl is-active --quiet bluetooth; then
        log_warn "Bluetooth service already running"
    else
        log_info "Enabling Bluetooth service..."
        sudo systemctl enable --now bluetooth
    fi

    # Firewall
    log_info "Configuring firewall..."
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --set-default-zone=public --permanent

    for service in ssh http https; do
        sudo firewall-cmd --permanent --add-service="$service" 2>/dev/null || true
    done

    # SSH brute-force rate limiting (max 6 connections per minute)
    if ! sudo firewall-cmd --permanent --list-rich-rules 2>/dev/null | grep -q "ssh.*limit"; then
        sudo firewall-cmd --permanent \
            --add-rich-rule='rule service name="ssh" limit value="6/m" accept'
        log_info "SSH rate limiting enabled."
    else
        log_warn "SSH rate limiting already configured"
    fi

    sudo firewall-cmd --reload

    summary_ok "Docker + Bluetooth + Firewall"
}

# ─── Section 16: Virtualization ──────────────────────────────────────────────

setup_virtualization() {
    log_section "Section 16: Virtualization"

    if sudo dnf group list --installed 2>/dev/null | grep -q "Virtualization"; then
        log_warn "Virtualization group already installed"
        summary_skip "Virtualization (already installed)"
        return
    fi

    log_info "Installing virtualization group..."
    sudo dnf groupinstall -y "Virtualization"
    sudo systemctl enable --now libvirtd

    for group in libvirt kvm; do
        if groups "$USER" | grep -q "$group"; then
            log_warn "User already in $group group"
        else
            sudo usermod -aG "$group" "$USER"
            log_info "Added $USER to $group group"
        fi
    done

    summary_ok "Virtualization"
}

# ─── Section 17: Snapper (Btrfs snapshots) ───────────────────────────────────

setup_snapper() {
    log_section "Section 17: Snapper (Btrfs Snapshots)"

    if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
        log_warn "Root filesystem is not Btrfs — skipping Snapper setup."
        summary_skip "Snapper (not Btrfs)"
        return
    fi

    dnf_install_bulk snapper python3-dnf-plugin-snapper btrfs-assistant

    # Root config
    if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then
        log_info "Creating Snapper root config..."
        sudo snapper -c root create-config /
        sudo snapper -c root set-config \
            TIMELINE_LIMIT_HOURLY=1 TIMELINE_LIMIT_DAILY=2 \
            TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0 \
            TIMELINE_LIMIT_YEARLY=0
    else
        log_warn "Snapper root config already exists"
    fi

    # Home config
    if ! sudo snapper list-configs 2>/dev/null | grep -q "^home"; then
        log_info "Creating Snapper home config..."
        sudo snapper -c home create-config /home
        sudo snapper -c home set-config \
            TIMELINE_LIMIT_HOURLY=2 TIMELINE_LIMIT_DAILY=3 \
            TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=1 \
            TIMELINE_LIMIT_YEARLY=0
    else
        log_warn "Snapper home config already exists"
    fi

    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

    # Take initial snapshot so there's something to roll back to immediately
    if ! sudo snapper -c root list 2>/dev/null | grep -q "post-fedora-setup"; then
        log_info "Taking initial post-setup snapshot..."
        sudo snapper -c root create --description "post-fedora-setup"
    else
        log_warn "Initial snapshot already exists"
    fi

    summary_ok "Snapper (Btrfs snapshots)"
}

# ─── Section 18: VS Code ─────────────────────────────────────────────────────

setup_vscode() {
    log_section "Section 18: VS Code Extensions + Theme"

    if ! cmd_exists code; then
        log_warn "VS Code not installed, skipping"
        summary_skip "VS Code setup (not installed)"
        return
    fi

    local EXTENSIONS=(
        "Catppuccin.catppuccin-vsc"
        "Catppuccin.catppuccin-vsc-icons"
    )

    for ext in "${EXTENSIONS[@]}"; do
        log_info "Installing VS Code extension: $ext"
        code --install-extension "$ext" --force
    done

    local VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
    if [[ -f "$VSCODE_SETTINGS" ]]; then
        log_warn "VS Code settings.json already exists, skipping"
        summary_skip "VS Code settings (already exists)"
    else
        mkdir -p "$(dirname "$VSCODE_SETTINGS")"
        cat > "$VSCODE_SETTINGS" <<'EOF'
{
  "workbench.colorTheme": "Catppuccin Mocha",
  "workbench.iconTheme": "catppuccin-mocha",
  "editor.fontFamily": "'MesloLGS NF', 'Droid Sans Mono', monospace",
  "editor.fontSize": 14,
  "editor.fontLigatures": true,
  "window.titleBarStyle": "custom",
  "workbench.startupEditor": "none"
}
EOF
        log_info "VS Code settings.json written with Catppuccin Mocha theme."
        summary_ok "VS Code Catppuccin Mocha"
    fi
}

# ─── Section 19: GNOME Configuration ─────────────────────────────────────────

configure_gnome() {
    log_section "Section 19: GNOME Configuration"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session detected (running via SSH?). Skipping GNOME settings."
        summary_skip "GNOME config (no D-Bus session)"
        return
    fi

    # Interface
    gsettings set org.gnome.desktop.interface color-scheme  'prefer-dark'
    gsettings set org.gnome.desktop.interface icon-theme    'Papirus-Dark'

    # Keyboard layouts
    gsettings set org.gnome.desktop.input-sources sources   "[('xkb', 'us'), ('xkb', 'ara')]"

    # Touchpad
    gsettings set org.gnome.desktop.peripherals.touchpad click-method   'areas'
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click   true
    gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true

    # Window management
    gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'

    # Dock
    gsettings set org.gnome.shell favorite-apps \
        "['org.gnome.Nautilus.desktop', 'google-chrome.desktop', 'com.mitchellh.ghostty.desktop']"

    # Default apps
    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || \
        log_warn "Could not set default browser"

    for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
        xdg-mime default vlc.desktop "$mime"
    done

    # Qt dark theme for non-GTK apps
    local ENV_FILE="/etc/environment"
    if ! grep -q "QT_QPA_PLATFORMTHEME" "$ENV_FILE" 2>/dev/null; then
        printf "\nQT_QPA_PLATFORMTHEME=qt6ct\nGTK_THEME=Adwaita:dark\n" | \
            sudo tee -a "$ENV_FILE" > /dev/null
        log_info "Qt dark theme environment variables set."
    else
        log_warn "Qt theme env vars already set"
    fi

    # Pre-configure qt5ct and qt6ct so Qt apps use dark theme without manual setup
    for qt_ct in qt5ct qt6ct; do
        local QT_CONF="$HOME/.config/$qt_ct/$qt_ct.conf"
        if [[ -f "$QT_CONF" ]]; then
            log_warn "$qt_ct already configured"
        else
            mkdir -p "$HOME/.config/$qt_ct"
            cat > "$QT_CONF" <<'EOF'
[Appearance]
color_scheme_path=
custom_palette=false
icon_theme=Papirus-Dark
standard_dialogs=default
style=Adwaita-Dark

[Fonts]
fixed=@Variant(\0\0\0@\0\0\0\x12Adwaita Mono\0\0\0\0\0\0\0\0\0\xfe\0\0\0\x11\0\0\0\0\0P\x10\x81)
general=@Variant(\0\0\0@\0\0\0\x12Adwaita Sans\0\0\0\0\0\0\0\0\0\xfe\0\0\0\x11\0\0\0\0\0P\x10\x81)

[Interface]
activate_item_on_single_click=1
buttonbox_layout=0
cursor_flash_time=1000
dialog_buttons_have_icons=1
double_click_interval=400
gui_effects=@Invalid()
keyboard_scheme=2
menus_have_icons=true
show_shortcuts_in_context_menus=true
stylesheets=@Invalid()
toolbutton_style=4
underline_shortcut=1
wheel_scroll_lines=3

[PaletteEditor]
geometry=@ByteArray()

[SettingsWindow]
geometry=@ByteArray()
EOF
            log_info "$qt_ct configured with Adwaita-Dark theme."
        fi
    done

    # System
    sudo hostnamectl set-hostname fedora
    sudo timedatectl set-timezone Africa/Casablanca

    powerprofilesctl set power-saver 2>/dev/null || \
        log_warn "Could not set power profile"

    # Extensions
    gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || \
        log_warn "Dash to Dock will activate after logout/login"
    gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null || \
        log_warn "AppIndicator will activate after logout/login"

    # Dash-to-dock: black opaque background
    gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
    gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true
    gsettings set org.gnome.shell.extensions.dash-to-dock background-color '#000000'
    gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 1.0

    log_warn "GNOME extensions require logout/login to activate."
    summary_ok "GNOME configuration"
}

# ─── Section 20: Dotfiles ────────────────────────────────────────────────────

setup_dotfiles() {
    log_section "Section 20: Dotfiles"

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

# ─── Section 21: Default Shell ───────────────────────────────────────────────

set_default_shell() {
    log_section "Section 21: Default Shell"

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
    log_warn "  • nvidia-drm.modeset=1 kernel argument"
    log_warn "  • Docker + libvirt group membership"
    log_warn "  • Default shell change to zsh"
    log_warn "  • GNOME extensions activation"
    log_warn "  • Qt dark theme (/etc/environment)"
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
    parse_args "$@"

    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)

    log_info "Fedora setup started at $(date)"
    echo ""

    preflight_checks

    run_section git           configure_git
    run_section dnf           configure_dnf
    run_section repos         enable_repos
    run_section upgrade       system_upgrade
    run_section packages      install_packages
    run_section ms-fonts      install_ms_fonts
    run_section extra-tools   install_extra_tools
    run_section ghostty       install_ghostty
    run_section flatpak       setup_flatpak
    run_section nvidia        install_nvidia
    run_section fonts         install_fonts
    run_section shell         install_shell_extras
    run_section node          install_node
    run_section ssh           setup_ssh
    run_section services      setup_services
    run_section virt          setup_virtualization
    run_section snapper       setup_snapper
    run_section vscode        setup_vscode
    run_section gnome         configure_gnome
    run_section dotfiles      setup_dotfiles
    run_section shell-default set_default_shell

    print_summary
    reboot_prompt

    log_info "Setup completed at $(date)"
}

main "$@"
