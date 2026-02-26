#!/bin/bash
# Bootstrap script for Duo Authentication Proxy deployment.
# Installs PowerShell (if needed) and downloads Deploy-DuoAuthProxy.ps1
# to the current directory for repeated use.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/OneMIT/duo-auth-proxy-deploy/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/OneMIT/duo-auth-proxy-deploy/main"
SCRIPT_NAME="Deploy-DuoAuthProxy.ps1"

echo "==> Checking for PowerShell..."

if command -v pwsh &>/dev/null; then
    echo "    PowerShell is already installed: $(pwsh --version)"
else
    echo "==> Installing PowerShell (sudo may prompt for your password)..."

    . /etc/os-release

    case "$ID" in
        ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -qq
            sudo apt-get install -y -qq wget apt-transport-https software-properties-common >/dev/null
            wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
            sudo dpkg -i /tmp/packages-microsoft-prod.deb
            rm /tmp/packages-microsoft-prod.deb
            sudo apt-get update -qq
            sudo apt-get install -y -qq powershell >/dev/null
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update -qq
            sudo apt-get install -y -qq wget apt-transport-https software-properties-common >/dev/null
            wget -q "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
            sudo dpkg -i /tmp/packages-microsoft-prod.deb
            rm /tmp/packages-microsoft-prod.deb
            sudo apt-get update -qq
            sudo apt-get install -y -qq powershell >/dev/null
            ;;
        rhel|centos|fedora|rocky|almalinux)
            sudo rpm -Uvh "https://packages.microsoft.com/config/rhel/${VERSION_ID%%.*}/packages-microsoft-prod.rpm" 2>/dev/null || true
            if command -v dnf &>/dev/null; then
                sudo dnf install -y -q powershell
            else
                sudo yum install -y -q powershell
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

echo "==> Downloading ${SCRIPT_NAME}..."
wget -q "${REPO_RAW}/${SCRIPT_NAME}" -O "${SCRIPT_NAME}" || \
    curl -fsSL "${REPO_RAW}/${SCRIPT_NAME}" -o "${SCRIPT_NAME}"

echo ""
echo "==> Ready! Run the deployment with:"
echo "    pwsh ./${SCRIPT_NAME}"
echo ""
echo "    Options:"
echo "      pwsh ./${SCRIPT_NAME} -Force                    # Skip confirmation prompts"
echo "      pwsh ./${SCRIPT_NAME} -SkipChecksumValidation   # Skip checksum check"
echo "      pwsh ./${SCRIPT_NAME} -Force -SkipChecksumValidation"
