#!/bin/bash
# Bootstrap script for Duo Authentication Proxy deployment.
# Installs PowerShell (if needed) and runs Deploy-DuoAuthProxy.ps1.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/OneMIT/duo-auth-proxy-deploy/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/OneMIT/duo-auth-proxy-deploy/main/install.sh | bash -s -- --skip-checksum --force

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/OneMIT/duo-auth-proxy-deploy/main"

# Pass-through arguments for the PowerShell script
PS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --skip-checksum) PS_ARGS+=("-SkipChecksumValidation") ;;
        --force)         PS_ARGS+=("-Force") ;;
        *)               PS_ARGS+=("$arg") ;;
    esac
done

echo "==> Checking for PowerShell..."

if command -v pwsh &>/dev/null; then
    echo "    PowerShell is already installed: $(pwsh --version)"
else
    echo "==> Installing PowerShell..."

    . /etc/os-release

    case "$ID" in
        ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq wget apt-transport-https software-properties-common >/dev/null
            wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
            dpkg -i /tmp/packages-microsoft-prod.deb
            rm /tmp/packages-microsoft-prod.deb
            apt-get update -qq
            apt-get install -y -qq powershell >/dev/null
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq wget apt-transport-https software-properties-common >/dev/null
            wget -q "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
            dpkg -i /tmp/packages-microsoft-prod.deb
            rm /tmp/packages-microsoft-prod.deb
            apt-get update -qq
            apt-get install -y -qq powershell >/dev/null
            ;;
        rhel|centos|fedora|rocky|almalinux)
            rpm -Uvh "https://packages.microsoft.com/config/rhel/${VERSION_ID%%.*}/packages-microsoft-prod.rpm" 2>/dev/null || true
            if command -v dnf &>/dev/null; then
                dnf install -y -q powershell
            else
                yum install -y -q powershell
            fi
            ;;
        *)
            echo "ERROR: Unsupported distro '$ID'. Install PowerShell manually:"
            echo "       https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
            exit 1
            ;;
    esac

    echo "    Installed: $(pwsh --version)"
fi

echo "==> Downloading Deploy-DuoAuthProxy.ps1..."
SCRIPT_PATH="/tmp/Deploy-DuoAuthProxy.ps1"
wget -q "${REPO_RAW}/Deploy-DuoAuthProxy.ps1" -O "$SCRIPT_PATH" || \
    curl -fsSL "${REPO_RAW}/Deploy-DuoAuthProxy.ps1" -o "$SCRIPT_PATH"

echo "==> Running Duo Auth Proxy deployment..."
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_PATH" "${PS_ARGS[@]}"

rm -f "$SCRIPT_PATH"
