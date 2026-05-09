#!/usr/bin/env bash

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

cmd_exists() {
    command -v "$1" &>/dev/null
}

user_in_group() {
    id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

has_nvidia_hardware() {
    # NVIDIA PCI vendor ID is 0x10de. Checking /sys avoids depending on lspci.
    grep -qi '^0x10de$' /sys/bus/pci/devices/*/vendor 2>/dev/null
}

has_asus_hardware() {
    local vendor product board
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    board="$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || true)"

    printf '%s\n%s\n%s\n' "$vendor" "$product" "$board" | grep -Eiq 'ASUSTeK|ASUS'
}

add_dnf_repo_from_url() {
    local url="$1"

    # DNF5 (Fedora 41+): addrepo --from-repofile
    if sudo dnf config-manager addrepo --from-repofile="$url" 2>/dev/null; then
        return 0
    fi

    # Fallback: download the .repo file directly — works on DNF4 and DNF5
    local filename
    filename=$(basename "${url%%\?*}")
    if curl -fsSL "$url" | sudo tee "/etc/yum.repos.d/${filename}" > /dev/null; then
        return 0
    fi

    log_warn "Could not add repo from $url — skipping"
    return 0
}

# Try to repair DNF file-conflict/multilib version mismatches, then callers retry.
# Common case: installing Steam/Wine pulls *.i686 while installed *.x86_64 is one
# build behind, producing "conflicts with file from package ...x86_64" errors.
dnf_repair_transaction_conflicts() {
    local output_file="$1"
    local pkgs=()

    if ! grep -qE 'conflicts with file from package|Rpm transaction failed|Transaction failed' "$output_file" 2>/dev/null; then
        return 1
    fi

    # Extract package names from strings like:
    #   mesa-vulkan-drivers-26.0.5-3.fc44.x86_64
    #   gnutls-3.8.13-1.fc44.i686
    # This strips from the first dash followed by a digit, leaving the name.
    mapfile -t pkgs < <(
        grep -oE '[A-Za-z0-9_+.-]+-[0-9][^[:space:]]*\.(x86_64|i686)' "$output_file" 2>/dev/null \
            | sed -E 's/-[0-9].*$//' \
            | sort -u
    )

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        log_warn "DNF transaction conflict detected; synchronizing affected packages: ${pkgs[*]}"
        sudo dnf distro-sync --refresh -y "${pkgs[@]}" || return 1
    else
        log_warn "DNF transaction conflict detected; refreshing and synchronizing installed packages"
        sudo dnf distro-sync --refresh -y || return 1
    fi
}

# Install multiple packages in one dnf call, skipping already-installed ones.
# On DNF transaction/file conflicts, automatically repair and retry once.
dnf_install_bulk() {
    local to_install=()
    for pkg in "$@"; do
        if pkg_installed "$pkg"; then
            log_warn "$pkg already installed, skipping"
        else
            to_install+=("$pkg")
        fi
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        return
    fi

    log_info "Installing: ${to_install[*]}"
    local dnf_log
    dnf_log="$(mktemp /tmp/fedora-setup-dnf.XXXXXX.log)"

    if sudo dnf install -y "${to_install[@]}" 2>&1 | tee "$dnf_log"; then
        rm -f "$dnf_log"
        return 0
    fi

    log_warn "DNF install failed; checking whether it can be repaired automatically..."
    if dnf_repair_transaction_conflicts "$dnf_log"; then
        log_info "Retrying install after DNF repair: ${to_install[*]}"
        if sudo dnf install -y "${to_install[@]}"; then
            rm -f "$dnf_log"
            return 0
        else
            local status=$?
            rm -f "$dnf_log"
            return "$status"
        fi
    fi

    rm -f "$dnf_log"
    return 1
}

err_handler() {
    log_error "Script failed at line $1. Check $LOG_FILE for details."
    exit 1
}
