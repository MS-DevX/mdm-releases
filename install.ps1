# ==============================================================================
# MDM Download Manager — One-Line Desktop Installer for Windows (PowerShell)
# Website:    https://marthdownloadmanager.msdevx.com
# Repository: https://github.com/MS-DevX/MDM
# ==============================================================================

$ErrorActionPreference = "Stop"

# Enable modern TLS protocols
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$DefaultRepo = "MS-DevX/mdm-releases"
$Repo = if ($env:MDM_REPO) { $env:MDM_REPO } else { $DefaultRepo }
$AppName = "MDM Download Manager"

Write-Host ""
Write-Host "Installing $AppName..." -ForegroundColor Cyan
Write-Host ""

# Check operating system (if running PowerShell Core on non-Windows)
if ($PSVersionTable.PSEdition -and -not ($IsWindows -or $env:OS -eq "Windows_NT")) {
    Write-Host "✗ Installation failed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Reason:" -ForegroundColor Yellow
    Write-Host "install.ps1 is intended for Windows PowerShell."
    Write-Host "For Linux and macOS, please run:"
    Write-Host "  curl -fsSL https://raw.githubusercontent.com/MS-DevX/MDM/main/install.sh | bash" -ForegroundColor Cyan
    exit 1
}

# ------------------------------------------------------------------------------
# Native Messaging Host Registration + Browser Integration (optional)
# ------------------------------------------------------------------------------
# The MDM browser extension talks to the desktop app through a native messaging
# host named com.mdm.native_host. The extension ID is deterministic (derived from
# the committed manifest key), so registration no longer requires pasting the ID
# shown at chrome://extensions. Control:
#   MDM_BROWSER_SETUP=none | auto   Skip or force (non-interactive) setup
#   MDM_EXTENSION_ID=xxxx           Override the stable extension ID
function Test-ArtifactChecksum {
    param([string]$FilePath, [string]$ArtifactName, [string[]]$ChecksumLines)
    $expected = $null
    foreach ($line in $ChecksumLines) {
        if ($line -match "^\s*([0-9a-fA-F]{64})\s+[\*\.]?([^\s]+)\s*$") {
            $hash = $matches[1]
            $file = [System.IO.Path]::GetFileName($matches[2])
            if ($file -ieq $ArtifactName) {
                $expected = $hash.ToLower()
                break
            }
        }
    }
    if (-not $expected) { return $false }
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    return ($expected -eq $actual)
}

function Register-NativeMessagingHost {
    param([string]$BaseUrl, [string]$Tag, [string]$ArchType, [string[]]$ChecksumLines, [string]$ExtensionId)

    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { "C:\Users\Default\AppData\Local" }
    $cliDir = Join-Path $localAppData "MDM\bin"
    $cliPath = Join-Path $cliDir "mdm.exe"
    $hostPath = Join-Path $cliDir "mdm-native-host.exe"
    $cliArtifact = "mdm-windows-$ArchType.exe"
    $hostArtifact = "mdm-native-host-windows-$ArchType.exe"

    New-Item -ItemType Directory -Path $cliDir -Force | Out-Null

    if (-not (Test-Path $cliPath) -or -not (Test-Path $hostPath)) {
        Write-Host "→ Fetching MDM CLI & native messaging host binary ($Tag)..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri "$BaseUrl/$cliArtifact" -OutFile $cliPath -UseBasicParsing
            Invoke-WebRequest -Uri "$BaseUrl/$hostArtifact" -OutFile $hostPath -UseBasicParsing
        } catch {
            Remove-Item -Path $cliPath, $hostPath -Force -ErrorAction SilentlyContinue
            Write-Host "! Registration binaries unavailable; native host registration deferred." -ForegroundColor Yellow
            Write-Host "  Run later with: mdm register-browser-host" -ForegroundColor Cyan
            return
        }
        if (-not (Test-ArtifactChecksum $cliPath $cliArtifact $ChecksumLines) -or
            -not (Test-ArtifactChecksum $hostPath $hostArtifact $ChecksumLines)) {
            Remove-Item -Path $cliPath, $hostPath -Force -ErrorAction SilentlyContinue
            Write-Host "! Checksum verification failed; native host registration deferred." -ForegroundColor Yellow
            Write-Host "  Run later with: mdm register-browser-host" -ForegroundColor Cyan
            return
        }
    }

    Write-Host "→ Registering native messaging host for extension '$ExtensionId'..." -ForegroundColor Gray
    if ([string]::IsNullOrWhiteSpace($ExtensionId)) {
        & $cliPath register-browser-host --binary-path $hostPath
        $cmd = "$cliPath register-browser-host --binary-path $hostPath"
    } else {
        & $cliPath register-browser-host --binary-path $hostPath --extension-id $ExtensionId
        $cmd = "$cliPath register-browser-host --binary-path $hostPath --extension-id $ExtensionId"
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Native messaging host registered for extension ID '$ExtensionId'." -ForegroundColor Green
    } else {
        Write-Host "! Native host registration command failed. Run later with:" -ForegroundColor Yellow
        Write-Host "  $cmd" -ForegroundColor Cyan
    }
}

# ------------------------------------------------------------------------------
# 1. Architecture Detection
# ------------------------------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
Write-Host "→ Detecting Windows architecture... $arch" -ForegroundColor Gray

switch ($arch) {
    "AMD64" { $archType = "x64" }
    "ARM64" { $archType = "arm64" }
    Default {
        Write-Host ""
        Write-Host "✗ Installation failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "Reason:" -ForegroundColor Yellow
        Write-Host "Unsupported Windows CPU architecture: $arch. Supported architectures: AMD64 (x64) and ARM64."
        exit 1
    }
}

# ------------------------------------------------------------------------------
# 2. Version & Release Resolution
# ------------------------------------------------------------------------------
function Test-ValidTag([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    if ($t -match "[\s:/\\`r`n`t]" -or $t -match "^(location|http|releases)") {
        return $false
    }
    return $true
}

$tag = $null

if ($env:MDM_VERSION) {
    if (-not (Test-ValidTag $env:MDM_VERSION)) {
        Write-Host ""
        Write-Host "✗ Installation failed" -ForegroundColor Red
        Write-Host "Reason: Specified MDM_VERSION '$env:MDM_VERSION' is invalid. Release tags must not contain spaces, colons, slashes, or control characters."
        exit 1
    }
    $tag = $env:MDM_VERSION
    Write-Host "→ Using explicitly requested version... $tag" -ForegroundColor Gray
} else {
    Write-Host "→ Finding latest release..." -ForegroundColor Gray
    $headers = @{
        "Accept" = "application/vnd.github.v3+json"
        "User-Agent" = "MDM-Windows-Installer"
    }

    # Step 1: GitHub Releases API (/releases/latest)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 15
        if ($release.tag_name -and (Test-ValidTag $release.tag_name)) {
            $tag = $release.tag_name.Trim()
        }
    } catch {}

    # Step 2: Fallback to Releases list API (/releases?per_page=1)
    if (-not $tag) {
        try {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=1" -Headers $headers -TimeoutSec 15
            if ($releases -and $releases[0].tag_name -and (Test-ValidTag $releases[0].tag_name)) {
                $tag = $releases[0].tag_name.Trim()
            }
        } catch {}
    }

    # Step 3: Fallback to redirect resolution strictly matching /releases/tag/<tag>
    if (-not $tag) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            $location = $resp.GetResponseHeader("Location")
            $resp.Close()

            if ($location -match "/releases/tag/([^/?#\s]+)") {
                $candidate = $matches[1].Trim()
                if (Test-ValidTag $candidate) {
                    $tag = $candidate
                }
            }
        } catch {}
    }

    # Step 4: Fallback to Git Tags API (/tags)
    if (-not $tag) {
        try {
            $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/tags?per_page=10" -Headers $headers -TimeoutSec 15
            foreach ($t in $tags) {
                if ($t.name -match "^v?[0-9]+\.[0-9]+(\.[0-9]+)?") {
                    if (Test-ValidTag $t.name) {
                        $tag = $t.name.Trim()
                        break
                    }
                }
            }
        } catch {}
    }
}

if (-not $tag -or -not (Test-ValidTag $tag)) {
    Write-Host ""
    Write-Host "✗ Installation failed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Reason:" -ForegroundColor Yellow
    Write-Host "Unable to determine the latest release from https://github.com/$Repo."
    Write-Host "You can specify a release manually: `$env:MDM_VERSION='v0.1.0'"
    exit 1
}

$version = $tag.TrimStart("v")
$desktopArtifact = "MDM-$version-windows-$archType.exe"

Write-Host "→ Selected release: $tag ($desktopArtifact)" -ForegroundColor Gray

# ------------------------------------------------------------------------------
# 3. Secure Temporary Download
# ------------------------------------------------------------------------------
$tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "mdm-install-" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $defaultBaseUrl = "https://github.com/$Repo/releases/download/$tag"
    $baseUrl = if ($env:MDM_BASE_URL) { $env:MDM_BASE_URL } else { $defaultBaseUrl }

    $installerUrl = "$baseUrl/$desktopArtifact"
    $checksumUrl = "$baseUrl/checksums.txt"
    $checksumFallbackUrl = "$baseUrl/SHA256SUMS"

    $installerPath = Join-Path $tempDir $desktopArtifact
    $checksumPath = Join-Path $tempDir "checksums.txt"

    Write-Host "→ Downloading $AppName Desktop Installer ($tag)..." -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    } catch {
        Write-Host ""
        Write-Host "✗ Installation failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "Reason:" -ForegroundColor Yellow
        Write-Host "Failed to download installer from: $installerUrl"
        Write-Host "Please verify that $tag contains package '$desktopArtifact'."
        exit 1
    }

    Write-Host "→ Fetching cryptographic checksums..." -ForegroundColor Gray
    $checksumDownloaded = $false
    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing
        $checksumDownloaded = $true
    } catch {
        try {
            Invoke-WebRequest -Uri $checksumFallbackUrl -OutFile $checksumPath -UseBasicParsing
            $checksumDownloaded = $true
        } catch {
            Write-Host ""
            Write-Host "✗ Installation failed" -ForegroundColor Red
            Write-Host ""
            Write-Host "Reason:" -ForegroundColor Yellow
            Write-Host "Failed to retrieve cryptographic checksum file from release $tag."
            exit 1
        }
    }

    # --------------------------------------------------------------------------
    # 4. Cryptographic SHA-256 Verification
    # --------------------------------------------------------------------------
    Write-Host "→ Verifying SHA-256 checksum..." -ForegroundColor Gray
    $checksumContent = Get-Content -Path $checksumPath

    $expectedHash = $null
    foreach ($line in $checksumContent) {
        if ($line -match "^\s*([0-9a-fA-F]{64})\s+[\*\.]?([^\s]+)\s*$") {
            $hash = $matches[1]
            $file = [System.IO.Path]::GetFileName($matches[2])
            if ($file -ieq $desktopArtifact) {
                $expectedHash = $hash.ToLower()
                break
            }
        }
    }

    if (-not $expectedHash) {
        Write-Host ""
        Write-Host "✗ Installation failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "Reason:" -ForegroundColor Yellow
        Write-Host "Checksum file does not contain an entry for $desktopArtifact."
        exit 1
    }

    $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash.ToLower()

    if ($expectedHash -ne $actualHash) {
        Write-Host ""
        Write-Host "✗ Installation failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "Reason:" -ForegroundColor Yellow
        Write-Host "The downloaded installer failed SHA-256 verification."
        Write-Host "Expected: $expectedHash"
        Write-Host "Actual:   $actualHash"
        Write-Host ""
        Write-Host "No unverified installer was executed."
        exit 1
    }

    Write-Host "✓ Checksum verified: $actualHash" -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 5. Execute Desktop Installer
    # --------------------------------------------------------------------------
    Write-Host "→ Installing $AppName to Windows..." -ForegroundColor Gray
    # Run the NSIS installer silently (/S) to install desktop shortcuts and Start Menu entries
    $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -PassThru -Wait

    # --------------------------------------------------------------------------
    # 6. Native Messaging Host Registration + Browser Integration (optional)
    # --------------------------------------------------------------------------
    # The extension ID is deterministic (derived from the committed manifest key),
    # so no ID look-up is needed anymore. Control:
    #   MDM_BROWSER_SETUP=none  Skip entirely;  MDM_BROWSER_SETUP=auto  Non-interactive opt-in
    #   MDM_EXTENSION_ID=xxxx   Override the stable extension ID (custom builds)
    Write-Host ""
    Write-Host "Browser integration (optional)" -ForegroundColor White
    $DefaultBrowserExtId = "jlhjhpchnlpgbgdcaniadhapcldphhae"
    $extId = $null
    if ($env:MDM_BROWSER_SETUP -eq "none") {
        $extId = "__skip__"
    } elseif ($env:MDM_EXTENSION_ID) {
        $extId = $env:MDM_EXTENSION_ID.Trim()
    } elseif ($env:MDM_BROWSER_SETUP -eq "auto") {
        $extId = ""  # auto (deterministic default)
    } elseif (-not [Console]::IsInputRedirected) {
        Write-Host "MDM registers a native messaging host for its browser extension so downloads can be intercepted from Chrome, Edge, Brave, Chromium, and Firefox. This downloads the small CLI + host binaries and configures the extension automatically (no ID to look up)." -ForegroundColor Gray
        $answer = (Read-Host "Set up browser integration now? [Y/n]").Trim()
        if ($answer -match "^(n|N|no)$") { $extId = "__skip__" } else { $extId = "" }
    } else {
        $extId = "__skip__"
    }

    if ($extId -eq "__skip__") {
        Write-Host "! Skipping browser integration setup. Register later with:" -ForegroundColor Yellow
        Write-Host "  mdm register-browser-host" -ForegroundColor Cyan
    } elseif ([string]::IsNullOrWhiteSpace($extId)) {
        Register-NativeMessagingHost -BaseUrl $baseUrl -Tag $tag -ArchType $archType -ChecksumLines $checksumContent -ExtensionId $DefaultBrowserExtId
    } elseif ($extId -notmatch "^[a-p]{32}$") {
        Write-Host "! Invalid extension ID ignored: $extId. Using the stable MDM ID." -ForegroundColor Yellow
        Register-NativeMessagingHost -BaseUrl $baseUrl -Tag $tag -ArchType $archType -ChecksumLines $checksumContent -ExtensionId $DefaultBrowserExtId
    } else {
        Register-NativeMessagingHost -BaseUrl $baseUrl -Tag $tag -ArchType $archType -ChecksumLines $checksumContent -ExtensionId $extId
    }

    # --------------------------------------------------------------------------
    # 7. Completion Instructions
    # --------------------------------------------------------------------------
    Write-Host ""
    Write-Host "✓ $AppName ($tag) installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "You can now launch MDM Download Manager from:" -ForegroundColor White
    Write-Host "  - Windows Start Menu" -ForegroundColor Cyan
    Write-Host "  - Desktop shortcut" -ForegroundColor Cyan
    Write-Host ""

} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
