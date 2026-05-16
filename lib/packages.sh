#!/usr/bin/env bash
# Per-distro package name mappings.
#
# Returns a space-separated list of package names for the current distro.
# Functions are named pkgs_<group> and read $DISTRO_FAMILY to branch.
#
# Usage:
#   pkg_install $(pkgs_system_tools)
#
# Mapping principles:
# - One function per logical group (system_tools, dev, codecs, ...).
# - Each function echoes packages, no side effects.
# - When a Fedora-specific package has no equivalent (e.g. RPM Fusion freeworld
#   codecs, mozilla-openh264), it's omitted on other distros — those distros
#   ship working codecs by default.
# - darwin functions return Homebrew formula/cask names. Casks (GUI apps) are
#   detected automatically via _brew_is_cask() in distro.sh.

# ─── System tools ─────────────────────────────────────────────────────────────

pkgs_system_tools() {
    case "$DISTRO_FAMILY" in
        fedora) echo "zsh git curl wget unzip tar bat fzf htop cabextract fastfetch fuse fuse-libs" ;;
        debian) echo "zsh git curl wget unzip tar bat fzf htop cabextract fastfetch fuse libfuse2" ;;
        arch)   echo "zsh git curl wget unzip tar bat fzf htop cabextract fastfetch fuse2" ;;
        darwin) echo "zsh git curl wget unzip bat fzf htop fastfetch" ;;
    esac
}

# ─── Dev tools ────────────────────────────────────────────────────────────────

pkgs_dev() {
    case "$DISTRO_FAMILY" in
        fedora) echo "podman python3 python3-pip golang gcc gcc-c++ make cmake clang" ;;
        debian) echo "podman python3 python3-pip golang-go gcc g++ make cmake clang" ;;
        arch)   echo "podman python python-pip go gcc make cmake clang" ;;
        darwin) echo "python3 go gcc make cmake llvm" ;;
    esac
}

# ─── Java (LTS preferred) ─────────────────────────────────────────────────────
# Echoes a candidate list — caller uses pkg_install_one to pick the first found.

pkgs_java_candidates() {
    case "$DISTRO_FAMILY" in
        fedora) echo "java-21-openjdk java-latest-openjdk java-17-openjdk" ;;
        debian) echo "openjdk-21-jdk openjdk-17-jdk default-jdk" ;;
        arch)   echo "jdk21-openjdk jdk17-openjdk jdk-openjdk" ;;
        darwin) echo "openjdk@21 openjdk@17 openjdk" ;;
    esac
}

# ─── Codecs / multimedia ──────────────────────────────────────────────────────
# On Fedora, requires RPM Fusion (handled in repos section).
# Ubuntu ships codecs in universe/multiverse; Arch ships in extra.
# macOS: VLC and ffmpeg cover playback and transcoding.

pkgs_codecs() {
    case "$DISTRO_FAMILY" in
        fedora)
            echo "vlc ffmpeg gstreamer1-plugins-good gstreamer1-plugins-bad-free \
                  gstreamer1-plugins-ugly gstreamer1-plugin-libav mozilla-openh264"
            ;;
        debian)
            echo "vlc ffmpeg gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
                  gstreamer1.0-plugins-ugly gstreamer1.0-libav ubuntu-restricted-extras"
            ;;
        arch)
            echo "vlc ffmpeg gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav"
            ;;
        darwin)
            echo "vlc ffmpeg"
            ;;
    esac
}

# ─── Gaming ───────────────────────────────────────────────────────────────────

pkgs_gaming() {
    case "$DISTRO_FAMILY" in
        fedora) echo "gamemode mangohud lutris goverlay" ;;
        debian) echo "gamemode mangohud lutris goverlay" ;;
        arch)   echo "gamemode mangohud lutris goverlay" ;;
        darwin) : ;;  # Linux gaming stack not available on macOS
    esac
}

# ─── Steam (separate; multilib handling differs) ──────────────────────────────

pkgs_steam() {
    case "$DISTRO_FAMILY" in
        fedora) echo "steam" ;;       # from RPM Fusion
        debian) echo "steam-installer" ;;
        arch)   echo "steam" ;;       # multilib repo must be enabled
        darwin) echo "steam" ;;       # Homebrew cask
    esac
}

# ─── Icon themes (universal) ─────────────────────────────────────────────────

pkgs_themes() {
    case "$DISTRO_FAMILY" in
        darwin) : ;;  # papirus is Linux-only
        *) echo "papirus-icon-theme" ;;
    esac
}

# ─── GNOME-only: tweaks + shell extensions ────────────────────────────────────

pkgs_gnome_only() {
    case "$DISTRO_FAMILY" in
        fedora) echo "gnome-tweaks gnome-shell-extension-dash-to-dock gnome-shell-extension-appindicator gnome-shell-extension-just-perfection gnome-shell-extension-user-theme" ;;
        debian) echo "gnome-tweaks gnome-shell-extension-dash-to-dock gnome-shell-extension-appindicator gnome-shell-extension-just-perfection gnome-shell-extension-user-theme" ;;
        arch)   echo "gnome-tweaks gnome-shell-extension-dash-to-dock gnome-shell-extension-appindicator gnome-shell-extension-just-perfection gnome-shell-extension-user-theme" ;;
        darwin) : ;;  # no GNOME on macOS
    esac
}

# ─── Nautilus helpers ─────────────────────────────────────────────────────────

pkgs_nautilus_customizations() {
    case "$DISTRO_FAMILY" in
        fedora) echo "sushi nautilus-open-any-terminal python3-nautilus-open-any-terminal wl-clipboard" ;;
        debian) echo "gnome-sushi nautilus-extension-gnome-terminal nautilus-admin wl-clipboard" ;;
        arch)   echo "sushi nautilus-open-any-terminal wl-clipboard" ;;
        darwin) : ;;  # no Nautilus on macOS
    esac
}

# ─── KDE-only: Plasma desktop helpers ─────────────────────────────────────────

pkgs_kde_only() {
    case "$DISTRO_FAMILY" in
        fedora) echo "dolphin konsole kio-extras kde-connect ark spectacle gwenview okular plasma-discover-flatpak" ;;
        debian) echo "dolphin konsole kio-extras kdeconnect ark spectacle gwenview okular plasma-discover-backend-flatpak" ;;
        arch)   echo "dolphin konsole kio-extras kdeconnect ark spectacle gwenview okular discover flatpak-kcm" ;;
        darwin) : ;;  # no KDE desktop setup on macOS
    esac
}

# ─── Qt platform theming ──────────────────────────────────────────────────────

pkgs_qt() {
    case "$DISTRO_FAMILY" in
        fedora) echo "qt5ct qt6ct" ;;
        debian) echo "qt5ct qt6ct" ;;
        arch)   echo "qt5ct qt6ct" ;;
        darwin) : ;;  # Qt theming is handled differently on macOS
    esac
}

# ─── Arabic fonts ─────────────────────────────────────────────────────────────

pkgs_fonts_arabic() {
    case "$DISTRO_FAMILY" in
        fedora) echo "google-noto-sans-arabic-fonts google-noto-naskh-arabic-fonts amiri-fonts" ;;
        debian) echo "fonts-noto fonts-noto-core fonts-hosny-amiri" ;;
        arch)   echo "noto-fonts ttf-amiri" ;;
        darwin) : ;;  # macOS ships fully-featured Arabic fonts; install extras via Font Book
    esac
}

# ─── Bluetooth ────────────────────────────────────────────────────────────────

pkgs_bluetooth() {
    case "$DISTRO_FAMILY" in
        fedora) echo "bluez" ;;
        debian) echo "bluez" ;;
        arch)   echo "bluez bluez-utils" ;;
        darwin) : ;;  # Bluetooth is built-in on macOS, no package needed
    esac
}

# ─── Bloat to remove ──────────────────────────────────────────────────────────

pkgs_bloat() {
    case "$DISTRO_FAMILY" in
        fedora) echo "gnome-tour gnome-maps gnome-weather gnome-contacts gnome-clocks simple-scan" ;;
        debian) echo "gnome-tour gnome-maps gnome-weather gnome-contacts gnome-clocks simple-scan" ;;
        arch)   echo "gnome-tour gnome-maps gnome-weather gnome-contacts gnome-clocks simple-scan" ;;
        darwin) : ;;  # nothing to debloat on macOS via package manager
    esac
}

# ─── Ghostty build deps ───────────────────────────────────────────────────────

pkgs_ghostty_build_deps() {
    case "$DISTRO_FAMILY" in
        fedora) echo "gtk4-devel gtk4-layer-shell-devel libadwaita-devel gettext" ;;
        debian) echo "libgtk-4-dev libgtk4-layer-shell-dev libadwaita-1-dev gettext" ;;
        arch)   echo "gtk4 gtk4-layer-shell libadwaita gettext" ;;
        darwin) : ;;  # macOS uses brew cask ghostty instead of building from source
    esac
}

# ─── Virtualization ───────────────────────────────────────────────────────────

pkgs_virt() {
    case "$DISTRO_FAMILY" in
        fedora) echo "qemu-kvm libvirt virt-manager virt-install bridge-utils edk2-ovmf swtpm" ;;
        debian) echo "qemu-kvm libvirt-daemon-system virt-manager virtinst bridge-utils ovmf swtpm" ;;
        arch)   echo "qemu-full libvirt virt-manager bridge-utils edk2-ovmf swtpm dnsmasq" ;;
        darwin) : ;;  # KVM/QEMU is Linux-only; use UTM or Parallels on macOS
    esac
}

# ─── Snapper (BTRFS) ──────────────────────────────────────────────────────────

pkgs_snapper() {
    case "$DISTRO_FAMILY" in
        fedora) echo "snapper python3-dnf-plugins-extras-snapper btrfs-assistant" ;;
        debian) echo "snapper btrfs-assistant" ;;
        arch)   echo "snapper snap-pac btrfs-assistant" ;;
        darwin) : ;;  # Btrfs/Snapper is Linux-only; macOS uses APFS + Time Machine
    esac
}

# ─── Firewall ─────────────────────────────────────────────────────────────────

pkgs_firewall() {
    case "$DISTRO_FAMILY" in
        fedora) echo "firewalld" ;;
        debian) echo "ufw" ;;
        arch)   echo "firewalld" ;;
        darwin) : ;;  # macOS has a built-in firewall via System Settings
    esac
}

# ─── Docker engine packages (when using upstream repo) ────────────────────────
# darwin installs Docker Desktop (a cask), handled separately in install_docker_engine.

pkgs_docker_engine() {
    # Same names across upstream Docker repos for all Linux distros
    echo "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
}

pkgs_docker_conflicts() {
    case "$DISTRO_FAMILY" in
        fedora)
            echo "docker docker-client docker-client-latest docker-common docker-latest \
                  docker-latest-logrotate docker-logrotate docker-selinux \
                  docker-engine-selinux docker-engine podman-docker \
                  moby-engine docker-cli containerd"
            ;;
        debian)
            echo "docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
            ;;
        arch)
            echo "docker"
            ;;
        darwin) : ;;  # no conflicts to remove on macOS
    esac
}

# ─── Microsoft fonts ──────────────────────────────────────────────────────────
# Each distro has a different mechanism — caller branches on $DISTRO_FAMILY.

pkgs_ms_fonts() {
    case "$DISTRO_FAMILY" in
        debian) echo "ttf-mscorefonts-installer" ;;   # universe/multiverse
        arch)   echo "ttf-ms-fonts" ;;                # AUR
        # fedora and darwin handled separately
    esac
}
