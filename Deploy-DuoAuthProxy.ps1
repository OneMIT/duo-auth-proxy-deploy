<#
.SYNOPSIS
    Installs or upgrades Duo Authentication Proxy on Linux or Windows.

.DESCRIPTION
    Auto-detects the operating system and performs a silent install or in-place
    upgrade of the Duo Authentication Proxy. On upgrade, the existing config is
    preserved by Duo's installer and a safety-net backup is created beforehand.

    Requires PowerShell 7+ (uses $IsWindows / $IsLinux automatic variables).
    Must be run as root/sudo on Linux or as Administrator on Windows.

.PARAMETER SkipChecksumValidation
    Skip the checksum validation step. By default the script attempts to scrape
    the expected hash from Duo's checksums page; if scraping fails it warns and
    continues. This switch skips the attempt entirely.

.PARAMETER Force
    Suppress confirmation prompts (e.g. upgrade confirmation).

.EXAMPLE
    # Fresh install on either OS (interactive)
    ./Deploy-DuoAuthProxy.ps1

.EXAMPLE
    # Upgrade, skip checksum, no prompts
    ./Deploy-DuoAuthProxy.ps1 -SkipChecksumValidation -Force
#>
[CmdletBinding()]
param(
    [switch]$SkipChecksumValidation,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs a native command and throws if it returns a non-zero exit code.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' exited with code $LASTEXITCODE"
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "   WARNING: $Message" -ForegroundColor Yellow
}

#endregion

#region 1 — Initialize: OS detection and privilege check

Write-Step "Detecting operating system..."

if ($IsLinux) {
    $OS = 'Linux'
    $InstallDir = '/opt/duoauthproxy'
    $DownloadUrl = 'https://dl.duosecurity.com/duoauthproxy-latest-src.tgz'
    $TempDir = '/tmp'

    # Verify we are root or can sudo (prompt for password if needed)
    $uid = & id -u
    if ($uid -eq '0') {
        Write-Success "Running on Linux as root."
    } else {
        Write-Host "   Sudo access required. You may be prompted for your password."
        # sudo -v prompts for password (if needed) and caches the credential.
        # Called directly (not via Invoke-NativeCommand) because -v collides
        # with PowerShell's -Verbose common parameter.
        & sudo @('-v')
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to obtain sudo privileges."
            exit 1
        }
        Write-Success "Running on Linux with sudo access."
    }
} elseif ($IsWindows) {
    $OS = 'Windows'
    $InstallDir = 'C:\Program Files\Duo Security Authentication Proxy'
    $DownloadUrl = 'https://dl.duosecurity.com/duoauthproxy-latest.exe'
    $TempDir = $env:TEMP

    # Auto-elevate to Administrator if needed (triggers UAC prompt)
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "   Administrator privileges required. Requesting elevation..."
        $scriptPath = $MyInvocation.MyCommand.Definition
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
        if ($SkipChecksumValidation) { $argList += '-SkipChecksumValidation' }
        if ($Force) { $argList += '-Force' }
        Start-Process -FilePath 'pwsh' -ArgumentList $argList -Verb RunAs -Wait
        exit $LASTEXITCODE
    }
    Write-Success "Running on Windows with Administrator privileges."
} else {
    Write-Error "Unsupported operating system. This script supports Linux and Windows only."
    exit 1
}

#endregion

#region 2 — Detect existing installation

Write-Step "Checking for existing Duo Auth Proxy installation..."

$ConfigPath = Join-Path $InstallDir 'conf' 'authproxy.cfg'
$IsUpgrade = Test-Path $ConfigPath

if ($IsUpgrade) {
    Write-Success "Existing installation found at $InstallDir — running in UPGRADE mode."

    if (-not $Force) {
        $answer = Read-Host "   Continue with upgrade? (y/N)"
        if ($answer -notin @('y', 'Y', 'yes', 'Yes')) {
            Write-Host "Upgrade cancelled." -ForegroundColor Yellow
            exit 0
        }
    }
} else {
    Write-Success "No existing installation found — running in INSTALL mode."
}

#endregion

#region 3 — Download latest installer

Write-Step "Resolving latest download URL..."

$headResponse = Invoke-WebRequest -Uri $DownloadUrl -Method Head
# Headers values are String[] in PowerShell 7 — unwrap to a single string
$contentDisposition = [string]($headResponse.Headers['Content-Disposition'])

if ($contentDisposition) {
    # Parse filename from: attachment; filename="duoauthproxy-x.y.z-src.tgz"
    if ($contentDisposition -match 'filename="?([^"]+)"?') {
        $Filename = $Matches[1]
    } else {
        $Filename = $contentDisposition -replace '.*filename=', '' -replace '"', ''
    }
} else {
    # Fallback: derive from the redirect URL or use a generic name
    $Filename = Split-Path $headResponse.BaseResponse.RequestMessage.RequestUri.AbsolutePath -Leaf
}

$Filename = $Filename.Trim()
$ResolvedUrl = "https://dl.duosecurity.com/$Filename"
$DownloadPath = Join-Path $TempDir $Filename

Write-Success "Latest version: $Filename"
Write-Step "Downloading $ResolvedUrl..."
Invoke-WebRequest -Uri $ResolvedUrl -OutFile $DownloadPath
Write-Success "Downloaded to $DownloadPath"

#endregion

#region 4 — Checksum validation (optional)

$ChecksumPassed = $false

if ($SkipChecksumValidation) {
    Write-Warn "Checksum validation skipped (-SkipChecksumValidation)."
} else {
    Write-Step "Validating checksum..."

    try {
        $checksumUrl = 'https://duo.com/docs/checksums#duo-authentication-proxy'
        $checksumPage = Invoke-WebRequest -Uri $checksumUrl
        $escapedFilename = [regex]::Escape($Filename)
        $checksumRegex = "([a-fA-F0-9]{64})\s*(?:<[^>]*>\s*)*$escapedFilename"

        if ($checksumPage.Content -match $checksumRegex) {
            $expectedHash = $Matches[1].Trim().ToUpper()
            $actualHash = (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash

            if ($expectedHash -eq $actualHash) {
                Write-Success "SHA256 checksum verified: $actualHash"
                $ChecksumPassed = $true
            } else {
                Write-Error "Checksum mismatch!`n   Expected: $expectedHash`n   Actual:   $actualHash"
                exit 1
            }
        } else {
            Write-Warn "Could not parse checksum from Duo's website. Continuing without validation."
        }
    } catch {
        Write-Warn "Checksum validation failed: $($_.Exception.Message). Continuing without validation."
    }
}

#endregion

# Wrap install/upgrade in try/finally for cleanup
$ExtractedDir = $null

try {

    #region 5 — Pre-upgrade steps

    if ($IsUpgrade) {
        Write-Step "Preparing for upgrade..."

        # Safety-net backup of config
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "${ConfigPath}.bak.${timestamp}"

        if ($IsLinux) {
            Invoke-NativeCommand sudo cp $ConfigPath $backupPath
        } else {
            Copy-Item -Path $ConfigPath -Destination $backupPath
        }
        Write-Success "Config backed up to $backupPath"

        # Stop the service
        Write-Step "Stopping Duo Auth Proxy service..."

        if ($IsLinux) {
            try {
                Invoke-NativeCommand sudo (Join-Path $InstallDir 'bin' 'authproxyctl') stop
                Write-Success "Service stopped."
            } catch {
                Write-Warn "Could not stop service (may not be running): $($_.Exception.Message)"
            }
        } else {
            try {
                Stop-Service -Name 'DuoAuthProxy' -Force -ErrorAction Stop
                Write-Success "Service stopped."
            } catch {
                Write-Warn "Could not stop service (may not be running): $($_.Exception.Message)"
            }
        }
    }

    #endregion

    #region 6 — Install / Upgrade

    if ($IsLinux) {
        # Extract tarball
        Write-Step "Extracting tarball..."
        Push-Location $TempDir
        Invoke-NativeCommand tar -xzf $DownloadPath
        $ExtractedDir = Join-Path $TempDir ($Filename -replace '\.tgz$', '')
        Write-Success "Extracted to $ExtractedDir"

        # Install build dependencies
        Write-Step "Installing build dependencies..."
        Invoke-NativeCommand sudo apt-get update -qq
        Invoke-NativeCommand sudo apt-get install -y build-essential libffi-dev zlib1g-dev
        Write-Success "Dependencies installed."

        # Build
        Write-Step "Building from source (this may take a few minutes)..."
        Push-Location $ExtractedDir
        Invoke-NativeCommand make
        Write-Success "Build complete."

        # Silent install (preserves existing config on upgrade)
        Write-Step "Running silent install..."
        Invoke-NativeCommand sudo ./duoauthproxy-build/install `
            --install-dir /opt/duoauthproxy `
            --service-user duo_authproxy_svc `
            --log-group duo_authproxy_grp `
            --create-init-script yes
        Pop-Location
        Pop-Location

    } else {
        # Windows: run EXE silent installer (handles install + upgrade)
        Write-Step "Running silent installer..."
        $process = Start-Process -FilePath $DownloadPath -ArgumentList '/S' -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installer exited with code $($process.ExitCode)"
        }
    }

    Write-Success "Installation complete."

    #endregion

    #region 7 — Post-install: start service and verify

    if ($IsUpgrade) {
        # Upgrade: existing config should be valid, so a start failure is an error
        Write-Step "Starting Duo Auth Proxy service..."

        if ($IsLinux) {
            Invoke-NativeCommand sudo (Join-Path $InstallDir 'bin' 'authproxyctl') start
        } else {
            Start-Service -Name 'DuoAuthProxy' -ErrorAction Stop
        }
        Write-Success "Service started."
    } else {
        # Fresh install: default config has placeholders, service won't start yet
        Write-Step "Skipping service start (fresh install — config needs to be set up first)."
    }

    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    if ($IsUpgrade) {
        Write-Host " Duo Auth Proxy UPGRADE complete!" -ForegroundColor Green
    } else {
        Write-Host " Duo Auth Proxy INSTALL complete!" -ForegroundColor Green
    }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " OS:          $OS"
    Write-Host " Install Dir: $InstallDir"
    Write-Host " Config:      $ConfigPath"
    if (-not $IsUpgrade) {
        Write-Host ""
        Write-Host " Next step: Edit $ConfigPath with your Duo integration settings," -ForegroundColor Yellow
        Write-Host " then start the service:" -ForegroundColor Yellow
        if ($IsLinux) {
            Write-Host "   sudo $InstallDir/bin/authproxyctl start" -ForegroundColor Yellow
        } else {
            Write-Host "   Start-Service -Name DuoAuthProxy" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    #endregion

} finally {

    #region 8 — Cleanup

    Write-Step "Cleaning up temporary files..."

    if (Test-Path $DownloadPath) {
        Remove-Item -Path $DownloadPath -Force
        Write-Success "Removed $DownloadPath"
    }

    if ($ExtractedDir -and (Test-Path $ExtractedDir)) {
        if ($IsLinux) {
            Invoke-NativeCommand sudo rm -rf $ExtractedDir
        } else {
            Remove-Item -Path $ExtractedDir -Recurse -Force
        }
        Write-Success "Removed $ExtractedDir"
    }

    #endregion
}
