#!/usr/bin/env bash

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

cmd_exists() {
    command -v "$1" &>/dev/null
}

# Install multiple packages in one dnf call, skipping already-installed ones
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
    sudo dnf install -y "${to_install[@]}"
}

err_handler() {
    log_error "Script failed at line $1. Check $LOG_FILE for details."
    exit 1
}
