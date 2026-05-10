#!/usr/bin/env bash
# Linux post-install setup script (Fedora, Ubuntu/Debian, Arch)
# Run as your regular user (not root), from a desktop session.
#
# Tested on: Fedora.
# Best-effort, untested on: Ubuntu, Debian, Arch.
#
# Usage:
#   bash setup.sh                        # run all sections
#   bash setup.sh --only gnome dotfiles  # run only these sections
#   bash setup.sh --skip nvidia snapper  # run all except these
#   bash setup.sh --list                 # list available sections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.linux-setup.log"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"
START_TIME=$(date +%s)

declare -a SUMMARY=()
declare -a ONLY_SECTIONS=()
declare -a SKIP_SECTIONS=()

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/distro.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/checks.sh"

summary_ok()   { SUMMARY+=("  ${GREEN}✓${NC}  $*"); }
summary_skip() { SUMMARY+=("  ${YELLOW}→${NC}  $*"); }
summary_fail() { SUMMARY+=("  ${RED}✗${NC}  $*"); }

# ─── Argument parsing ─────────────────────────────────────────────────────────

list_sections() {
    echo "Available sections:"
    echo "  git          Git configuration"
    echo "  dnf          Package manager tuning (parallel downloads, etc.)"
    echo "  repos        Enable third-party repositories (Chrome, Docker, VS Code, gh, Wine, ProtonVPN; RPM Fusion on Fedora)"
    echo "  upgrade      System upgrade"
    echo "  packages     Package installation"
    echo "  ms-fonts     Microsoft fonts"
    echo "  extra-tools  yt-dlp, Neovim, opencode, opencode Desktop"
    echo "  ghostty      Build Ghostty from source (zvm + Zig)"
    echo "  flatpak      Flatpak + Flathub + Spotify"
    echo "  nvidia       NVIDIA drivers (auto-skips if no NVIDIA GPU)"
    echo "  asus         asusctl/supergfxctl (auto-skips if not ASUS hardware)"
    echo "  fonts        MesloLGS NF fonts"
    echo "  shell        Oh My Zsh + Powerlevel10k + plugins"
    echo "  node         fnm + Node.js LTS + npm globals"
    echo "  ssh          SSH key setup"
    echo "  services     Docker + Bluetooth + Firewall"
    echo "  security     Light security checks; strict hardening is opt-in via env vars"
    echo "  virt         Virtualization (KVM/QEMU)"
    echo "  snapper      Btrfs snapshots (skipped if not Btrfs)"
    echo "  vscode       VS Code extensions + Catppuccin Mocha theme"
    echo "  gnome        GNOME configuration"
    echo "  rice         Catppuccin cursor, Inter font, Blur my Shell, Night Light"
    echo "  dotfiles     Dotfiles symlinks"
    echo "  shell-default  Set zsh as default shell"
    echo ""
    echo "Examples:"
    echo "  bash setup.sh --only gnome dotfiles"
    echo "  bash setup.sh --skip nvidia snapper virt"
    echo "  ENABLE_STRICT_CRYPTO=1 ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security"
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

# Sections that require internet access (downloads, dnf, git clone, flatpak…).
# Anything not listed runs offline (git config, gnome settings, dotfiles, etc.).
NETWORK_SECTIONS=(
    repos upgrade packages ms-fonts extra-tools ghostty flatpak
    nvidia asus fonts shell node ssh vscode rice virt snapper
)

section_needs_internet() {
    local slug="$1" s
    for s in "${NETWORK_SECTIONS[@]}"; do
        [[ "$s" == "$slug" ]] && return 0
    done
    return 1
}

run_section() {
    local slug="$1"
    local fn="$2"
    if ! should_run "$slug"; then
        log_warn "Skipping: $slug"
        return
    fi
    if section_needs_internet "$slug" && ! require_internet "$slug"; then
        return
    fi
    "$fn"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

install_gnome_ext() {
    local uuid="$1"
    local name="$2"

    if gnome-extensions list 2>/dev/null | grep -q "^${uuid}$"; then
        log_warn "Extension $name already installed"
        return
    fi

    local GNOME_VER
    GNOME_VER=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    if [[ -z "$GNOME_VER" ]]; then
        log_warn "Could not determine GNOME Shell version; skipping $name"
        return
    fi

    local EXT_INFO
    EXT_INFO=$(curl -fsSL \
        "https://extensions.gnome.org/extension-info/?uuid=${uuid}&shell_version=${GNOME_VER}" 2>/dev/null)

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('download_url',''))" \
        <<< "$EXT_INFO" 2>/dev/null || true)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        log_warn "Could not resolve download URL for $name (GNOME $GNOME_VER)"
        return
    fi

    local EXT_ZIP="/tmp/${uuid}.zip"
    curl -fsSL "https://extensions.gnome.org${DOWNLOAD_URL}" -o "$EXT_ZIP"
    gnome-extensions install --force "$EXT_ZIP"
    rm -f "$EXT_ZIP"
    log_info "Installed extension: $name"
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

# ─── Section 2: Package Manager Configuration ────────────────────────────────

configure_dnf() {
    log_section "Section 2: Package Manager Configuration"

    case "$PKG_MGR" in
        dnf)
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
            ;;
        apt)
            # apt: enable parallel downloads + assume-yes by default
            local APT_CONF="/etc/apt/apt.conf.d/99setup"
            if [[ ! -f "$APT_CONF" ]]; then
                sudo tee "$APT_CONF" > /dev/null <<'EOF'
Acquire::Queue-Mode "host";
Acquire::http::Pipeline-Depth "10";
APT::Get::Assume-Yes "true";
EOF
                log_info "apt tuned (parallel + default-yes)"
            else
                log_warn "apt already tuned"
            fi
            ;;
        pacman)
            # pacman: parallel downloads + colour
            local PACMAN_CONF="/etc/pacman.conf"
            if ! grep -q '^ParallelDownloads' "$PACMAN_CONF"; then
                sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' "$PACMAN_CONF"
                log_info "pacman ParallelDownloads enabled"
            else
                log_warn "pacman ParallelDownloads already set"
            fi
            if ! grep -qE '^Color' "$PACMAN_CONF"; then
                sudo sed -i 's/^#Color/Color/' "$PACMAN_CONF"
                log_info "pacman Color enabled"
            fi
            # Enable multilib for Steam/Wine on Arch
            if ! grep -qE '^\[multilib\]' "$PACMAN_CONF"; then
                sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/{s/^#//}' "$PACMAN_CONF"
                sudo pacman -Sy --noconfirm
                log_info "pacman multilib enabled"
            fi
            ;;
    esac

    summary_ok "Package manager configuration"
}

# ─── Section 3: Repositories ─────────────────────────────────────────────────

enable_repos_fedora() {
    dnf_install_bulk dnf-plugins-core

    if ! pkg_installed rpmfusion-free-release; then
        log_info "Enabling RPM Fusion Free..."
        dnf_run_optional install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    else
        log_warn "RPM Fusion Free already enabled"
    fi

    if ! pkg_installed rpmfusion-nonfree-release; then
        log_info "Enabling RPM Fusion Nonfree..."
        dnf_run_optional install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
    else
        log_warn "RPM Fusion Nonfree already enabled"
    fi

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

    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
        log_info "Adding Docker CE repository..."
        add_dnf_repo_from_url https://download.docker.com/linux/fedora/docker-ce.repo
    else
        log_warn "Docker CE repo already configured"
    fi

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

    if [[ ! -f /etc/yum.repos.d/gh-cli.repo ]]; then
        log_info "Adding GitHub CLI repository..."
        add_dnf_repo_from_url https://cli.github.com/packages/rpm/gh-cli.repo
    else
        log_warn "GitHub CLI repo already configured"
    fi

    if [[ ! -f /etc/yum.repos.d/winehq.repo ]]; then
        log_info "Adding WineHQ repository..."
        add_dnf_repo_from_url "https://dl.winehq.org/wine-builds/fedora/$(rpm -E %fedora)/winehq.repo"
    else
        log_warn "WineHQ repo already configured"
    fi

    if ! rpm -q protonvpn-stable-release &>/dev/null; then
        log_info "Adding ProtonVPN repository..."
        local PVN_RPM="/tmp/protonvpn-stable-release.rpm"
        local PVN_URL="https://repo.protonvpn.com/fedora-$(rpm -E %fedora)-stable/protonvpn-stable-release/protonvpn-stable-release-1.0.3-1.noarch.rpm"
        if curl -fLo "$PVN_RPM" "$PVN_URL" 2>/dev/null; then
            dnf_run_optional install -y "$PVN_RPM"
            sudo dnf check-update --refresh 2>/dev/null || true
            rm -f "$PVN_RPM"
        else
            log_warn "ProtonVPN repo RPM not available for Fedora $(rpm -E %fedora) — skipping"
        fi
    else
        log_warn "ProtonVPN repo already configured"
    fi
}

enable_repos_debian() {
    sudo apt-get update -qq
    pkg_install ca-certificates curl gnupg apt-transport-https software-properties-common

    # Enable universe + multiverse on Ubuntu (no-op on plain Debian)
    if cmd_exists add-apt-repository && [[ "$DISTRO" == "ubuntu" ]]; then
        sudo add-apt-repository -y universe || true
        sudo add-apt-repository -y multiverse || true
    fi

    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    local arch
    arch=$(dpkg --print-architecture)

    # Google Chrome
    add_apt_repo google-chrome \
        "https://dl.google.com/linux/linux_signing_key.pub" \
        "deb [arch=$arch signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main"

    # Docker CE — vendor instructs different paths for ubuntu vs debian
    local docker_path="ubuntu"
    [[ "$DISTRO" == "debian" ]] && docker_path="debian"
    add_apt_repo docker \
        "https://download.docker.com/linux/$docker_path/gpg" \
        "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_path $codename stable"

    # VS Code
    add_apt_repo vscode \
        "https://packages.microsoft.com/keys/microsoft.asc" \
        "deb [arch=$arch signed-by=/etc/apt/keyrings/vscode.gpg] https://packages.microsoft.com/repos/code stable main"

    # GitHub CLI
    add_apt_repo github-cli \
        "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
        "deb [arch=$arch signed-by=/etc/apt/keyrings/github-cli.gpg] https://cli.github.com/packages stable main"

    # WineHQ
    sudo dpkg --add-architecture i386 || true
    add_apt_repo winehq \
        "https://dl.winehq.org/wine-builds/winehq.key" \
        "deb [arch=$arch signed-by=/etc/apt/keyrings/winehq.gpg] https://dl.winehq.org/wine-builds/$DISTRO/ $codename main"

    log_info "Repos configured for $DISTRO"
}

enable_repos_arch() {
    # Arch: most "vendor repos" are AUR. Bootstrap yay so subsequent installs
    # can pull from AUR transparently. extra/multilib are enabled in section 2.
    bootstrap_aur
    log_info "AUR helper bootstrapped (Chrome/VS Code/Wine/ProtonVPN come from AUR)"
}

enable_repos() {
    log_section "Section 3: Enable Repositories"

    case "$DISTRO_FAMILY" in
        fedora) enable_repos_fedora ;;
        debian) enable_repos_debian ;;
        arch)   enable_repos_arch ;;
    esac

    summary_ok "Repositories"
}

# ─── Section 4: System Upgrade ───────────────────────────────────────────────

system_upgrade() {
    log_section "Section 4: System Upgrade"
    log_info "Running system upgrade with refreshed metadata (this may take a while)..."
    pm_upgrade

    # Firmware updates via fwupd (UEFI, SSD, peripherals)
    if cmd_exists fwupdmgr; then
        log_info "Checking for firmware updates..."
        sudo fwupdmgr refresh --force 2>/dev/null || true
        sudo fwupdmgr update --no-reboot-check 2>/dev/null || \
            log_warn "No firmware updates available or fwupd could not connect"
    else
        log_warn "fwupdmgr not found, skipping firmware updates"
    fi

    summary_ok "System upgrade + firmware"
}

# ─── Section 5: Package Installation ─────────────────────────────────────────

install_docker_engine() {
    # Remove conflicting unofficial/distro Docker packages before installing
    # Docker Engine from the upstream repo. Package list differs per distro.
    local conflicts
    read -ra conflicts <<< "$(pkgs_docker_conflicts)"
    pkg_remove "${conflicts[@]}"

    case "$DISTRO_FAMILY" in
        fedora|debian)
            # Upstream Docker repo configured in enable_repos
            pkg_install $(pkgs_docker_engine)
            ;;
        arch)
            # Arch ships docker in extra; docker-compose plugin is included
            pkg_install docker docker-buildx docker-compose
            ;;
    esac
}

install_chrome() {
    case "$DISTRO_FAMILY" in
        fedora) pkg_install google-chrome-stable ;;
        debian) pkg_install google-chrome-stable ;;
        arch)   pkg_install google-chrome ;;   # AUR
    esac
}

install_protonvpn() {
    case "$DISTRO_FAMILY" in
        fedora) pkg_install proton-vpn-gnome-desktop ;;
        debian) pkg_install proton-vpn-gnome-desktop ;;
        arch)   pkg_install proton-vpn-gtk-app ;;   # AUR
    esac
}

install_vscode() {
    case "$DISTRO_FAMILY" in
        fedora) pkg_install code ;;
        debian) pkg_install code ;;
        arch)   pkg_install visual-studio-code-bin ;;   # AUR
    esac
}

install_gh_cli() {
    case "$DISTRO_FAMILY" in
        fedora)
            if ! pkg_installed gh; then
                log_info "Installing gh from the official GitHub CLI repo..."
                dnf_run_optional install -y --repo gh-cli gh || \
                    log_warn "Could not install gh from gh-cli repo"
            else
                log_warn "gh already installed"
            fi
            ;;
        debian) pkg_install gh ;;
        arch)   pkg_install github-cli ;;
    esac
}

install_wine() {
    case "$DISTRO_FAMILY" in
        fedora)
            if [[ -f /etc/yum.repos.d/winehq.repo ]] && ! pkg_installed winehq-stable; then
                log_info "Installing winehq-stable from WineHQ repo..."
                dnf_run_optional install -y winehq-stable || \
                    log_warn "winehq-stable install failed; multilib may still be syncing"
            fi
            ;;
        debian)
            sudo apt-get install -y --install-recommends winehq-stable \
                || log_warn "winehq-stable install failed (multilib/i386 arch may need setup)"
            ;;
        arch)
            pkg_install wine wine-mono wine-gecko
            ;;
    esac
}

install_packages() {
    log_section "Section 5: Package Installation"

    # Multilib sync is Fedora-specific (mirror lag between x86_64/i686 in
    # enabled repos can break Steam/Wine installs). Skip elsewhere.
    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        log_info "Synchronizing multilib-sensitive packages before installing Steam/Wine..."
        mapfile -t multilib_specs < <(dnf_multilib_synced_specs mesa-vulkan-drivers gnutls)
        if [[ ${#multilib_specs[@]} -gt 0 ]]; then
            dnf_run_optional distro-sync --refresh --allowerasing -y "${multilib_specs[@]}" || \
                log_warn "Could not synchronize mesa-vulkan-drivers/gnutls; continuing"
        else
            log_warn "Skipping multilib sync: no arch-aligned upgrades available right now"
        fi
    fi

    install_docker_engine

    # Java — pick first available LTS
    pkg_install_one $(pkgs_java_candidates)

    # Bulk install via per-distro mappings
    pkg_install $(pkgs_system_tools) \
                $(pkgs_dev) \
                $(pkgs_codecs) \
                $(pkgs_gaming) \
                $(pkgs_libreoffice) \
                $(pkgs_steam) \
                $(pkgs_gnome) \
                $(pkgs_qt) \
                $(pkgs_fonts_arabic) \
                $(pkgs_bluetooth)

    install_chrome
    install_vscode
    install_protonvpn
    install_gh_cli
    install_wine

    # Fedora-only: swap ffmpeg-free → full ffmpeg + AMD VA-API freeworld drivers
    # (these come from RPM Fusion; no direct equivalent on Ubuntu/Arch — those
    # ship working VA-API stacks by default).
    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        if rpm -q ffmpeg-free &>/dev/null && ! rpm -q ffmpeg &>/dev/null; then
            log_info "Swapping ffmpeg-free → ffmpeg for full codec support..."
            dnf_run_optional swap -y ffmpeg-free ffmpeg --allowerasing
        else
            log_warn "ffmpeg already correct"
        fi

        for pkg in mesa-va-drivers mesa-vdpau-drivers; do
            local free_pkg="${pkg}-freeworld"
            if pkg_installed "$free_pkg"; then
                log_warn "$free_pkg already installed"
            else
                log_info "Swapping ${pkg}.x86_64 → ${free_pkg}.x86_64..."
                (dnf_run_optional swap -y "${pkg}.x86_64" "${free_pkg}.x86_64" --allowerasing) || \
                    log_warn "Could not swap $pkg → $free_pkg — skipping"
            fi
        done
        (dnf_install_bulk libva-utils) || log_warn "Could not install libva-utils — skipping"
    else
        # Other distros: just ensure VA-API utils are installed
        case "$DISTRO_FAMILY" in
            debian) pkg_install vainfo intel-media-va-driver-non-free i965-va-driver ;;
            arch)   pkg_install libva-utils intel-media-driver libva-mesa-driver ;;
        esac
    fi

    # Remove preinstalled GNOME bloat
    pkg_remove $(pkgs_bloat)

    summary_ok "Packages"
}

# ─── Section 6: Microsoft Fonts ──────────────────────────────────────────────

install_ms_fonts() {
    log_section "Section 6: Microsoft Fonts"

    case "$DISTRO_FAMILY" in
        fedora)
            if rpm -q msttcore-fonts-installer &>/dev/null; then
                log_warn "Microsoft fonts already installed, skipping"
                summary_skip "Microsoft fonts (already installed)"
                return
            fi
            local TMP_RPM="/tmp/msttcore-fonts-installer.rpm"
            log_info "Downloading Microsoft fonts installer..."
            curl -fLo "$TMP_RPM" \
                "https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm"
            dnf_run_optional install -y "$TMP_RPM"
            rm -f "$TMP_RPM"
            ;;
        debian)
            # ttf-mscorefonts-installer (multiverse on Ubuntu, contrib on Debian)
            # accepts the EULA via debconf; pre-seed it for non-interactive install.
            echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
                | sudo debconf-set-selections
            pkg_install ttf-mscorefonts-installer
            ;;
        arch)
            pkg_install ttf-ms-fonts   # AUR
            ;;
    esac

    log_info "Microsoft fonts installed."
    summary_ok "Microsoft fonts"
}

# ─── Section 7: Extra Tools (yt-dlp, Neovim, opencode, opencode Desktop) ──────

install_extra_tools() {
    log_section "Section 7: Extra Tools (yt-dlp, Neovim, opencode, opencode Desktop)"

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

    # opencode — official install script per https://opencode.ai/docs/
    if cmd_exists opencode; then
        log_warn "opencode already installed"
        summary_skip "opencode (already installed)"
    else
        log_info "Installing opencode via the official install script..."
        local OC_SCRIPT="/tmp/opencode-install.sh"
        if curl -fsSL https://opencode.ai/install -o "$OC_SCRIPT"; then
            bash "$OC_SCRIPT" && summary_ok "opencode" || summary_fail "opencode"
            rm -f "$OC_SCRIPT"
        else
            log_warn "Could not download opencode install script, skipping"
            summary_fail "opencode"
        fi
    fi

    # opencode Desktop — package from GitHub releases (anomalyco/opencode)
    if pkg_installed opencode || pkg_installed opencode-desktop; then
        log_warn "opencode Desktop already installed"
        summary_skip "opencode Desktop (already installed)"
    else
        log_info "Installing opencode Desktop..."
        local ocd_pattern
        case "$DISTRO_FAMILY" in
            fedora) ocd_pattern="x86_64.rpm" ;;
            debian) ocd_pattern="amd64.deb" ;;
            arch)
                # No prebuilt Arch package — fall back to AppImage in /opt
                ocd_pattern="x86_64.AppImage"
                ;;
        esac

        local OCD_URL
        OCD_URL=$(curl -fsSL "https://api.github.com/repos/anomalyco/opencode/releases/latest" \
            | python3 -c "
import sys, json
pat = sys.argv[1]
d = json.loads(sys.stdin.read())
for a in d.get('assets', []):
    if a['name'].endswith(pat):
        print(a['browser_download_url'])
        break
" "$ocd_pattern")

        if [[ -n "$OCD_URL" ]]; then
            local OCD_TMP="/tmp/opencode-desktop.${ocd_pattern##*.}"
            curl -fLo "$OCD_TMP" "$OCD_URL"
            if [[ "$ocd_pattern" == *AppImage ]]; then
                sudo install -m 0755 "$OCD_TMP" /opt/opencode-desktop.AppImage
                sudo ln -sf /opt/opencode-desktop.AppImage /usr/local/bin/opencode-desktop
                summary_ok "opencode Desktop (AppImage)"
            else
                install_local_pkg "$OCD_TMP" && summary_ok "opencode Desktop" || summary_fail "opencode Desktop"
            fi
            rm -f "$OCD_TMP"
        else
            log_warn "Could not resolve opencode Desktop URL for $ocd_pattern, skipping"
            summary_fail "opencode Desktop"
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
    pkg_install $(pkgs_ghostty_build_deps)

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
        | grep '"tag_name"' | grep -o '"[^"]*"' | tail -1 | tr -d '"' || true)
    if [[ -z "$GHOSTTY_TAG" ]]; then
        log_warn "Could not determine latest Ghostty release tag — skipping"
        summary_fail "Ghostty"
        return 0
    fi
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

    case "$DISTRO_FAMILY" in
        fedora) pkg_install flatpak gnome-software-plugin-flatpak ;;
        debian) pkg_install flatpak gnome-software-plugin-flatpak ;;
        arch)   pkg_install flatpak ;;
    esac

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

    # GNOME Extension Manager is distributed via Flathub as documented upstream.
    if flatpak list 2>/dev/null | grep -q "com.mattjakeman.ExtensionManager"; then
        log_warn "Extension Manager already installed"
    else
        log_info "Installing GNOME Extension Manager from Flathub..."
        flatpak install -y flathub com.mattjakeman.ExtensionManager
        summary_ok "GNOME Extension Manager"
    fi
}

# ─── Section 10: NVIDIA Drivers ───────────────────────────────────────────────

install_nvidia_fedora() {
    if pkg_installed akmod-nvidia; then
        log_warn "akmod-nvidia already installed, skipping"
        summary_skip "NVIDIA drivers (already installed)"
        return
    fi
    log_info "Installing NVIDIA drivers (RPM Fusion)..."
    dnf_run_optional install -y \
        akmod-nvidia \
        xorg-x11-drv-nvidia-cuda \
        xorg-x11-drv-nvidia-libs.i686 \
        nvidia-vaapi-driver \
        nvidia-settings

    if ! sudo grubby --info=ALL 2>/dev/null | grep -q "nvidia-drm.modeset=1"; then
        log_info "Enabling nvidia-drm.modeset=1 for Wayland..."
        sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=1"
    else
        log_warn "nvidia-drm.modeset=1 already set"
    fi
}

install_nvidia_debian() {
    if pkg_installed nvidia-driver; then
        log_warn "nvidia-driver already installed, skipping"
        summary_skip "NVIDIA drivers (already installed)"
        return
    fi
    log_info "Installing NVIDIA drivers via ubuntu-drivers / nvidia-driver..."
    if cmd_exists ubuntu-drivers; then
        sudo ubuntu-drivers install || pkg_install nvidia-driver-535
    else
        # Debian: nvidia-driver from non-free; ensure non-free enabled
        pkg_install nvidia-driver firmware-misc-nonfree libnvidia-encode1 nvidia-vaapi-driver || true
    fi
}

install_nvidia_arch() {
    if pkg_installed nvidia-dkms; then
        log_warn "nvidia-dkms already installed, skipping"
        summary_skip "NVIDIA drivers (already installed)"
        return
    fi
    log_info "Installing NVIDIA drivers (nvidia-dkms)..."
    pkg_install nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings libva-nvidia-driver

    # Add nvidia-drm.modeset=1 to kernel cmdline (GRUB)
    if [[ -f /etc/default/grub ]] && ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
        sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
}

install_nvidia() {
    log_section "Section 10: NVIDIA Drivers"

    if ! has_nvidia_hardware; then
        log_warn "No NVIDIA GPU detected, skipping NVIDIA drivers"
        summary_skip "NVIDIA drivers (no NVIDIA GPU detected)"
        return
    fi

    case "$DISTRO_FAMILY" in
        fedora) install_nvidia_fedora ;;
        debian) install_nvidia_debian ;;
        arch)   install_nvidia_arch ;;
    esac

    echo ""
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "  NVIDIA: kernel module will build on first boot."
    log_warn "  Do NOT skip the reboot at the end of this script."
    log_warn "  If Secure Boot is enabled, you must enroll the MOK key."
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    summary_ok "NVIDIA drivers (reboot required)"
}

# ─── Section 11: ASUS Linux Tools ────────────────────────────────────────────

install_asus_tools() {
    log_section "Section 11: ASUS Linux Tools"

    if ! has_asus_hardware; then
        log_warn "No ASUS hardware detected, skipping asusctl"
        summary_skip "ASUS tools (not ASUS hardware)"
        return
    fi

    if pkg_installed asusctl && pkg_installed supergfxctl; then
        log_warn "ASUS tools already installed"
    else
        case "$DISTRO_FAMILY" in
            fedora)
                log_info "ASUS hardware detected. Enabling ASUS Linux COPR..."
                if ! sudo dnf copr list --enabled 2>/dev/null | grep -q "lukenukem/asus-linux"; then
                    if ! dnf_run_with_repair copr enable -y lukenukem/asus-linux; then
                        log_warn "Could not enable lukenukem/asus-linux COPR — skipping ASUS tools"
                        summary_fail "ASUS tools"
                        return 0
                    fi
                else
                    log_warn "ASUS Linux COPR already enabled"
                fi
                log_info "Installing asusctl and supergfxctl..."
                if ! dnf_run_with_repair install -y asusctl supergfxctl; then
                    log_warn "Could not install ASUS tools — skipping"
                    summary_fail "ASUS tools"
                    return 0
                fi
                ;;
            debian)
                # No official PPA upstream; the asus-linux project provides
                # source builds. Skip on Debian/Ubuntu — direct user to source.
                log_warn "asusctl is not packaged for Debian/Ubuntu. See https://asus-linux.org/guides/ubuntu-guide/"
                summary_skip "ASUS tools (build from source on Debian/Ubuntu)"
                return 0
                ;;
            arch)
                log_info "Installing asusctl and supergfxctl from AUR..."
                pkg_install asusctl supergfxctl
                ;;
        esac
    fi

    # Best-effort, non-blocking configuration. Each command is timeout-limited
    # and failure is logged but never aborts the setup.
    timeout 15s sudo systemctl enable --now asusd 2>/dev/null || \
        log_warn "Could not enable asusd service"
    timeout 15s sudo systemctl enable --now supergfxd 2>/dev/null || \
        log_warn "Could not enable supergfxd service"

    if cmd_exists asusctl; then
        timeout 10s asusctl profile -P Quiet 2>/dev/null || \
            log_warn "Could not set ASUS profile to Quiet/power-saver"
        timeout 10s asusctl -c 80 2>/dev/null || \
            log_warn "Could not set ASUS battery charge limit to 80%"
    else
        log_warn "asusctl command not found after install; skipping ASUS profile config"
    fi

    log_info "Leaving ASUS GPU mode unchanged; change it manually with supergfxctl if needed"
    summary_ok "ASUS tools"
}

# ─── Section 12: Fonts ───────────────────────────────────────────────────────

install_fonts() {
    log_section "Section 12: Fonts (MesloLGS NF)"

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
        log_warn "fnm binary not found at $FNM_BIN after install — skipping Node.js setup"
        summary_fail "fnm + Node.js"
        return 0
    fi

    log_info "Installing Node.js LTS via fnm..."
    "$FNM_BIN" install --lts
    "$FNM_BIN" default lts-latest

    local NPM_BIN
    NPM_BIN="$("$FNM_BIN" exec --using=lts-latest which npm 2>/dev/null || true)"

    if [[ -z "$NPM_BIN" ]]; then
        log_warn "npm not found via fnm — skipping global npm packages"
        summary_fail "npm global packages"
        return 0
    fi

    # pkg → CLI binary used to detect a working install installed elsewhere
    # (e.g. pi-coding-agent ships its own pi-node prefix containing pnpm,
    # which `npm list -g` against fnm's prefix would miss).
    local NPM_GLOBALS=(
        "@anthropic-ai/claude-code|claude"
        "@earendil-works/pi-coding-agent|pi"
        "pnpm|pnpm"
    )

    for entry in "${NPM_GLOBALS[@]}"; do
        local pkg="${entry%%|*}"
        local bin="${entry#*|}"
        if "$NPM_BIN" list -g "$pkg" &>/dev/null || cmd_exists "$bin"; then
            log_warn "$pkg already installed"
        else
            log_info "Installing $pkg..."
            "$NPM_BIN" install -g "$pkg" || \
                log_warn "Could not install $pkg — continuing"
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

    # Docker (containerd is bundled on Arch; separate service on Fedora/Debian)
    log_info "Enabling Docker service..."
    sudo systemctl enable --now docker || log_warn "Could not enable docker service"
    sudo systemctl enable --now containerd 2>/dev/null || true

    if user_in_group docker; then
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
    pkg_install $(pkgs_firewall)
    case "$DISTRO_FAMILY" in
        fedora|arch)
            sudo systemctl enable --now firewalld
            sudo firewall-cmd --set-default-zone=public
            sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
            log_warn "Inbound HTTP/HTTPS are not opened by default; add them manually if this machine hosts web services."

            if ! sudo firewall-cmd --permanent --list-rich-rules 2>/dev/null | grep -q "ssh.*limit"; then
                sudo firewall-cmd --permanent \
                    --add-rich-rule='rule service name="ssh" limit value="6/m" accept'
                log_info "SSH rate limiting enabled."
            else
                log_warn "SSH rate limiting already configured"
            fi
            sudo firewall-cmd --reload
            ;;
        debian)
            sudo ufw allow ssh
            sudo ufw limit ssh   # rate-limit ssh
            sudo ufw --force enable
            log_info "ufw configured (ssh allowed + rate-limited)"
            ;;
    esac

    # Boot time: disable NetworkManager-wait-online (saves ~15-20s on desktops)
    if systemctl is-enabled NetworkManager-wait-online.service &>/dev/null; then
        sudo systemctl disable NetworkManager-wait-online.service
        log_info "Disabled NetworkManager-wait-online (faster boot)"
    else
        log_warn "NetworkManager-wait-online already disabled"
    fi

    # SSD TRIM
    if systemctl is-enabled fstrim.timer &>/dev/null; then
        log_warn "fstrim.timer already enabled"
    else
        log_info "Enabling fstrim.timer..."
        sudo systemctl enable --now fstrim.timer
    fi

    # zram: use zstd compression (better ratio than default lzo-rle)
    local ZRAM_CONF="/etc/systemd/zram-generator.conf.d/zstd.conf"
    if [[ -f "$ZRAM_CONF" ]]; then
        log_warn "zram zstd already configured"
    else
        sudo mkdir -p /etc/systemd/zram-generator.conf.d
        printf '[zram0]\ncompression-algorithm = zstd\n' | \
            sudo tee "$ZRAM_CONF" > /dev/null
        log_info "zram compression set to zstd (takes effect after reboot)"
    fi

    summary_ok "Services"
}

# ─── Section 16: Security Checks / Optional Hardening ───────────────────────
#
# Defaults are intentionally conservative to avoid breaking VPNs, corporate
# networks, captive portals, legacy SSH hosts, or custom SELinux workflows.
#
# Optional strict mode examples:
#   ENABLE_STRICT_CRYPTO=1 bash setup.sh --only security
#   ENABLE_DNS_OVER_TLS=1 bash setup.sh --only security
#   FORCE_SELINUX_ENFORCING=1 bash setup.sh --only security
#
# Revert crypto policy:  sudo update-crypto-policies --set DEFAULT
# Revert DNS over TLS:   sudo rm /etc/systemd/resolved.conf.d/99-dns-over-tls.conf && sudo systemctl restart systemd-resolved

setup_security() {
    log_section "Section 16: Security Checks / Optional Hardening"

    # Crypto policy: Fedora-only (update-crypto-policies is from crypto-policies pkg).
    if cmd_exists update-crypto-policies; then
        local current_crypto_policy
        current_crypto_policy="$(update-crypto-policies --show 2>/dev/null || true)"
        if [[ "${ENABLE_STRICT_CRYPTO:-0}" == "1" ]]; then
            if [[ "$current_crypto_policy" == *"NO-SHA1"* ]]; then
                log_warn "Crypto policy already includes NO-SHA1"
            else
                sudo update-crypto-policies --set DEFAULT:NO-SHA1
                log_info "Crypto policy set to DEFAULT:NO-SHA1"
                log_warn "  Revert: sudo update-crypto-policies --set DEFAULT"
            fi
        else
            log_info "Crypto policy: ${current_crypto_policy:-unknown}"
            log_warn "Strict crypto skipped. Set ENABLE_STRICT_CRYPTO=1 to disable SHA-1 system-wide."
        fi
    else
        log_warn "update-crypto-policies not available on this distro — skipping crypto policy"
    fi

    # DNS over TLS via systemd-resolved is opt-in to avoid network breakage.
    local DNS_CONF="/etc/systemd/resolved.conf.d/99-dns-over-tls.conf"
    if [[ "${ENABLE_DNS_OVER_TLS:-0}" == "1" ]]; then
        if [[ -f "$DNS_CONF" ]]; then
            log_warn "DNS over TLS already configured"
        else
            sudo mkdir -p /etc/systemd/resolved.conf.d
            sudo tee "$DNS_CONF" > /dev/null <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=yes
EOF
            sudo systemctl restart systemd-resolved
            log_info "DNS over TLS configured (Cloudflare + Quad9)"
            log_warn "  Revert: sudo rm $DNS_CONF && sudo systemctl restart systemd-resolved"
        fi
    else
        log_warn "DNS over TLS skipped. Set ENABLE_DNS_OVER_TLS=1 to enable it."
    fi

    # MAC: SELinux on Fedora, AppArmor on Debian/Ubuntu, neither default on Arch.
    if cmd_exists getenforce; then
        local selinux_state
        selinux_state="$(getenforce 2>/dev/null || echo unknown)"
        if echo "$selinux_state" | grep -qi "enforcing"; then
            log_info "SELinux: enforcing"
        elif [[ "${FORCE_SELINUX_ENFORCING:-0}" == "1" ]]; then
            log_warn "SELinux is $selinux_state — setting enforcing because FORCE_SELINUX_ENFORCING=1"
            sudo setenforce 1 2>/dev/null || true
            sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
            log_info "SELinux set to enforcing"
        else
            log_warn "SELinux is $selinux_state. Set FORCE_SELINUX_ENFORCING=1 to enforce it."
        fi
    elif cmd_exists aa-status; then
        if sudo aa-status --enabled 2>/dev/null; then
            log_info "AppArmor: enabled"
        else
            log_warn "AppArmor not enabled — install/enable manually if desired"
        fi
    else
        log_warn "No MAC framework detected (no SELinux or AppArmor)"
    fi

    summary_ok "Security checks / optional hardening"
}

# ─── Section 17: Virtualization ──────────────────────────────────────────────

setup_virtualization() {
    log_section "Section 17: Virtualization"

    # On Fedora, the "Virtualization" group is the canonical install path; on
    # other distros use the package list directly.
    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        if sudo dnf group list --installed 2>/dev/null | grep -q "Virtualization"; then
            log_warn "Virtualization group already installed"
            summary_skip "Virtualization (already installed)"
            return
        fi
        log_info "Installing virtualization group..."
        dnf_run_optional group install -y "virtualization" || dnf_run_optional groupinstall -y "Virtualization"
    else
        log_info "Installing virtualization packages..."
        pkg_install $(pkgs_virt)
    fi

    # Service name: libvirtd (Fedora/Debian) or libvirtd.service (Arch — same)
    sudo systemctl enable --now libvirtd || log_warn "Could not enable libvirtd"

    for group in libvirt kvm; do
        if user_in_group "$group"; then
            log_warn "User already in $group group"
        else
            sudo usermod -aG "$group" "$USER"
            log_info "Added $USER to $group group"
        fi
    done

    summary_ok "Virtualization"
}

# ─── Section 18: Snapper (Btrfs snapshots) ───────────────────────────────────

setup_snapper() {
    log_section "Section 18: Snapper (Btrfs Snapshots)"

    if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q btrfs; then
        log_warn "Root filesystem is not Btrfs — skipping Snapper setup."
        summary_skip "Snapper (not Btrfs)"
        return
    fi

    pkg_install $(pkgs_snapper)

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
    if ! sudo snapper -c root list 2>/dev/null | grep -q "post-setup"; then
        log_info "Taking initial post-setup snapshot..."
        sudo snapper -c root create --description "post-setup"
    else
        log_warn "Initial snapshot already exists"
    fi

    summary_ok "Snapper (Btrfs snapshots)"
}

# ─── Section 19: VS Code ─────────────────────────────────────────────────────

setup_vscode() {
    log_section "Section 19: VS Code Extensions + Theme"

    if ! cmd_exists code; then
        log_warn "VS Code not installed, skipping"
        summary_skip "VS Code setup (not installed)"
        return
    fi

    local EXTENSIONS=(
        # Theme
        "Catppuccin.catppuccin-vsc"
        "Catppuccin.catppuccin-vsc-icons"
        # Language support
        "vscjava.vscode-java-pack"
        "ms-python.python"
        "ms-python.vscode-pylance"
        "golang.go"
        "llvm-vs-code-extensions.vscode-clangd"
        "ms-azuretools.vscode-docker"
        # Linting / formatting
        "esbenp.prettier-vscode"
        "dbaeumer.vscode-eslint"
        "charliermarsh.ruff"
        "timonwong.shellcheck"
        # Quality of life
        "usernamehw.errorlens"
        "eamodio.gitlens"
        "mhutchie.git-graph"
        "oderwat.indent-rainbow"
        "christian-kohler.path-intellisense"
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
  "editor.rulers": [100],
  "editor.minimap.enabled": false,
  "editor.bracketPairColorization.enabled": true,
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "esbenp.prettier-vscode",

  "files.autoSave": "onFocusChange",

  "window.titleBarStyle": "custom",
  "workbench.startupEditor": "none",

  "terminal.integrated.fontFamily": "'MesloLGS NF'",

  "[python]": {
    "editor.defaultFormatter": "charliermarsh.ruff"
  },
  "[java]": {
    "editor.defaultFormatter": "redhat.java"
  },
  "[go]": {
    "editor.defaultFormatter": "golang.go",
    "editor.formatOnSave": true
  },
  "[c]": {
    "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd"
  },
  "[cpp]": {
    "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd"
  },
  "[shellscript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  }
}
EOF
        log_info "VS Code settings.json written."
        summary_ok "VS Code extensions + config"
    fi
}

# ─── Section 20: GNOME Configuration ─────────────────────────────────────────

configure_gnome() {
    log_section "Section 20: GNOME Configuration"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session detected (running via SSH?). Skipping GNOME settings."
        summary_skip "GNOME config (no D-Bus session)"
        return
    fi

    # Interface. Do not force GTK_THEME/gtk-theme: that breaks GTK4/libadwaita apps
    # like GNOME Settings. Use the supported dark preference instead.
    gsettings set org.gnome.desktop.interface color-scheme  'prefer-dark'
    gsettings reset org.gnome.desktop.interface gtk-theme 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme    'Papirus-Dark'

    # Keyboard layouts
    gsettings set org.gnome.desktop.input-sources sources   "[('xkb', 'us'), ('xkb', 'ara')]"

    # Touchpad
    gsettings set org.gnome.desktop.peripherals.touchpad click-method   'areas'
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click   true
    gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true

    # Dock
    gsettings set org.gnome.shell favorite-apps \
        "['org.gnome.Nautilus.desktop', 'google-chrome.desktop', 'com.mitchellh.ghostty.desktop']"

    # Default apps
    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || \
        log_warn "Could not set default browser"

    for mime in video/mp4 video/x-matroska video/x-msvideo video/webm video/quicktime; do
        xdg-mime default vlc.desktop "$mime"
    done

    # Qt platform theme for non-GTK apps. Also remove any old GTK_THEME override:
    # it is a blunt GTK env var and makes GTK4/libadwaita apps look broken.
    local ENV_FILE="/etc/environment"
    if grep -q '^GTK_THEME=' "$ENV_FILE" 2>/dev/null; then
        sudo sed -i '/^GTK_THEME=/d' "$ENV_FILE"
        log_info "Removed GTK_THEME override from /etc/environment."
    fi
    # If a prior run exported GTK_THEME into the already-running user manager,
    # logout may not clear it while other sessions are still active. Override it
    # to empty for this boot; a full user-manager restart/reboot removes it.
    if systemctl --user show-environment 2>/dev/null | grep -q '^GTK_THEME='; then
        systemctl --user set-environment GTK_THEME= 2>/dev/null || true
        dbus-update-activation-environment --systemd GTK_THEME= 2>/dev/null || true
        log_warn "Cleared stale GTK_THEME for this session; reboot to remove it entirely."
    fi
    if grep -q '^QT_QPA_PLATFORMTHEME=' "$ENV_FILE" 2>/dev/null; then
        sudo sed -i 's/^QT_QPA_PLATFORMTHEME=.*/QT_QPA_PLATFORMTHEME=qt6ct/' "$ENV_FILE"
        log_info "Qt platform theme environment variable already present."
    else
        printf "\nQT_QPA_PLATFORMTHEME=qt6ct\n" | \
            sudo tee -a "$ENV_FILE" > /dev/null
        log_info "Qt platform theme environment variable set."
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
    # Hostname: don't override a user-customized one. Replace only the default
    # placeholders distros ship with (localhost, hostname-set-by-installer).
    local current_host
    current_host="$(hostnamectl --static 2>/dev/null || hostname)"
    case "$current_host" in
        localhost|localhost.localdomain|fedora|ubuntu|debian|archlinux|""|"$DISTRO")
            sudo hostnamectl set-hostname "$DISTRO"
            log_info "Hostname set to $DISTRO"
            ;;
        *)
            log_warn "Hostname already customized ($current_host), leaving unchanged"
            ;;
    esac
    sudo timedatectl set-timezone Africa/Casablanca

    powerprofilesctl set power-saver 2>/dev/null || \
        log_warn "Could not set power profile"

    # Extensions
    gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || \
        log_warn "Dash to Dock will activate after logout/login"
    gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null || \
        log_warn "AppIndicator will activate after logout/login"

    # Dash-to-dock: black opaque background
    if gsettings list-schemas | grep -qx 'org.gnome.shell.extensions.dash-to-dock'; then
        gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
        gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true
        gsettings set org.gnome.shell.extensions.dash-to-dock background-color '#000000'
        gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 1.0
    else
        log_warn "Dash-to-dock schema not available; skipping dock appearance settings"
    fi

    log_warn "GNOME extensions require logout/login to activate."

    # Remove GNOME Software from autostart (saves 100-900 MB RAM)
    local GNOME_SW_AUTOSTART="/etc/xdg/autostart/org.gnome.Software.desktop"
    if [[ -f "$GNOME_SW_AUTOSTART" ]]; then
        sudo rm -f "$GNOME_SW_AUTOSTART"
        log_info "Removed GNOME Software from autostart"
    else
        log_warn "GNOME Software autostart already removed"
    fi

    # Privacy: disable automatic problem reporting (crash data to Red Hat)
    gsettings set org.gnome.desktop.privacy report-technical-problems false

    # Nautilus: show folders before files
    gsettings set org.gtk.Settings.FileChooser sort-directories-first true
    gsettings set org.gnome.nautilus.preferences sort-directories-first true 2>/dev/null || true

    summary_ok "GNOME configuration"
}

# ─── Section 21: Ricing ───────────────────────────────────────────────────────

setup_rice() {
    log_section "Section 21: Ricing (Catppuccin cursor + fonts + extensions)"

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_warn "No D-Bus session — skipping rice setup"
        summary_skip "Rice (no D-Bus session)"
        return
    fi

    # Inter font
    if ls "$HOME/.local/share/fonts/" 2>/dev/null | grep -qi "^inter"; then
        log_warn "Inter font already installed"
    else
        log_info "Installing Inter font..."
        local INTER_ZIP="/tmp/inter.zip"
        local INTER_URL
        INTER_URL=$(curl -fsSL https://api.github.com/repos/rsms/inter/releases/latest \
            | grep -o '"browser_download_url": *"[^"]*Inter[^"]*\.zip"' \
            | grep -o 'https://[^"]*' | head -1 || true)
        if [[ -z "$INTER_URL" ]]; then
            log_warn "Could not resolve Inter font URL, skipping"
        else
            curl -fLo "$INTER_ZIP" "$INTER_URL"
            mkdir -p "$HOME/.local/share/fonts/Inter"
            unzip -q "$INTER_ZIP" "*.ttf" -d "$HOME/.local/share/fonts/Inter" 2>/dev/null || \
                unzip -q "$INTER_ZIP" -d "$HOME/.local/share/fonts/Inter"
            fc-cache -f "$HOME/.local/share/fonts"
            rm -f "$INTER_ZIP"
            log_info "Inter font installed."
        fi
    fi

    # GTK theme: use GNOME default (Adwaita). Reset in case a prior run set Catppuccin.
    gsettings reset org.gnome.desktop.interface gtk-theme 2>/dev/null || true

    # Catppuccin cursor
    if ls "$HOME/.local/share/icons/" 2>/dev/null | grep -qi "catppuccin.*mocha.*cursor"; then
        log_warn "Catppuccin cursor already installed"
    else
        log_info "Installing Catppuccin cursor..."
        local CURSOR_ZIP="/tmp/catppuccin-cursors.zip"
        local CURSOR_URL
        CURSOR_URL=$(curl -fsSL https://api.github.com/repos/catppuccin/cursors/releases/latest \
            | grep -oi '"browser_download_url": *"[^"]*mocha[^"]*dark[^"]*\.zip"' \
            | grep -o 'https://[^"]*' | head -1 || true)
        if [[ -z "$CURSOR_URL" ]]; then
            log_warn "Could not resolve Catppuccin cursor URL, skipping"
        else
            curl -fLo "$CURSOR_ZIP" "$CURSOR_URL"
            mkdir -p "$HOME/.local/share/icons"
            unzip -q "$CURSOR_ZIP" -d "$HOME/.local/share/icons/"
            rm -f "$CURSOR_ZIP"
            log_info "Catppuccin cursor installed."
        fi
    fi

    # Apply cursor theme
    local CURSOR_THEME
    CURSOR_THEME=$(ls "$HOME/.local/share/icons/" 2>/dev/null | grep -i "catppuccin.*mocha.*cursor" | head -1 || true)
    [[ -n "$CURSOR_THEME" ]] && \
        gsettings set org.gnome.desktop.interface cursor-theme "$CURSOR_THEME"

    gsettings set org.gnome.desktop.interface font-name          'Inter 12'
    gsettings set org.gnome.desktop.interface document-font-name 'Inter 12'
    gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS NF 12'
    gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Inter Bold 12'

    # GNOME extensions
    install_gnome_ext "blur-my-shell@aunetx"           "Blur my Shell"
    install_gnome_ext "rounded-window-corners@fxgn"    "Rounded Window Corners Reborn"

    gnome-extensions enable user-theme@gnome-shell-extensions.gcampax.github.com 2>/dev/null || true
    gnome-extensions enable blur-my-shell@aunetx 2>/dev/null || \
        log_warn "Blur my Shell will activate after logout/login"
    gnome-extensions enable rounded-window-corners@fxgn 2>/dev/null || \
        log_warn "Rounded Window Corners will activate after logout/login"

    # Night Light (8pm → 7am, warm 4000K)
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled           true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from      20.0
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to        7.0
    gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature        4000

    summary_ok "Ricing"
}

# ─── Section 22: Dotfiles ────────────────────────────────────────────────────

setup_dotfiles() {
    log_section "Section 22: Dotfiles"

    local FILES=(
        ".zshrc"
        ".p10k.zsh"
        ".config/ghostty/config"
        ".config/fontconfig/fonts.conf"
        ".pi/agent/settings.json"
        ".pi/agent/extensions/bell-notifications.ts"
        ".pi/agent/extensions/clipboard-rendering.ts"
        ".pi/agent/extensions/diff.ts"
        ".pi/agent/extensions/effort.ts"
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

# ─── Section 23: Default Shell ───────────────────────────────────────────────

set_default_shell() {
    log_section "Section 23: Default Shell"

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

    log_info "Linux setup started at $(date)"
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
    run_section asus          install_asus_tools
    run_section fonts         install_fonts
    run_section shell         install_shell_extras
    run_section node          install_node
    run_section ssh           setup_ssh
    run_section services      setup_services
    run_section security      setup_security
    run_section virt          setup_virtualization
    run_section snapper       setup_snapper
    run_section vscode        setup_vscode
    run_section gnome         configure_gnome
    run_section rice          setup_rice
    run_section dotfiles      setup_dotfiles
    run_section shell-default set_default_shell

    print_summary
    reboot_prompt

    log_info "Setup completed at $(date)"
}

main "$@"
