#!/usr/bin/env bash
# ==============================================================================
# MDM Download Manager — One-Line Desktop Installer for Linux & macOS
# Website:    https://marthdownloadmanager.msdevx.com
# Repository: https://github.com/MS-DevX/MDM
# ==============================================================================

set -euo pipefail

REPO="${MDM_REPO:-MS-DevX/mdm-releases}"
APP_NAME="MDM Download Manager"
BIN_NAME="mdm"
DEFAULT_BIN_DIR="${HOME}/.local/bin"
BIN_DIR="${MDM_BIN_DIR:-$DEFAULT_BIN_DIR}"

# Color codes (only when stdout is a terminal)
if [ -t 1 ]; then
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    CYAN=''
    GREEN=''
    RED=''
    YELLOW=''
    BOLD=''
    NC=''
fi

info() {
    printf "${CYAN}→${NC} %b\n" "$1"
}

success() {
    printf "${GREEN}✓${NC} %b\n" "$1"
}

warn() {
    printf "${YELLOW}!${NC} %b\n" "$1"
}

fail() {
    printf "${RED}✗ Installation failed${NC}\n\n" >&2
    printf "${BOLD}Reason:${NC}\n%b\n\n" "$1" >&2
    printf "No unverified binary was installed.\n" >&2
    exit 1
}

# Verifies a downloaded artifact against the release checksums.txt by name.
# Returns 0 only when a matching SHA-256 entry exists and matches.
# Usage: verify_sha256 <file> <artifact-basename>
verify_sha256() {
    local file="$1"
    local name="$2"
    local expected=""
    expected=$(grep -E "[[:space:]]${name}$" "${TMP_DIR}/checksums.txt" 2>/dev/null | head -n1 | awk '{print $1}' || true)
    if [ -z "$expected" ]; then
        expected=$(grep -E "[[:space:]](\*|\./)?${name}$" "${TMP_DIR}/checksums.txt" 2>/dev/null | head -n1 | awk '{print $1}' || true)
    fi
    [ -n "$expected" ] || return 1

    local actual=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        return 1
    fi

    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    [ "$expected" = "$actual" ]
}

validate_tag() {
    local t="${1:-}"
    [ -n "$t" ] || return 1
    case "$t" in
        *[[:space:]]*|*:*|*/*|*\\*|*[[:cntrl:]]*)
            return 1
            ;;
        location*|Location*|http*|HTTP*|releases)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

extract_json_tag() {
    local json="$1"
    [ -n "$json" ] || return 0
    local parsed_tag=""

    # 1. Try jq if installed
    if command -v jq >/dev/null 2>&1; then
        parsed_tag=$(printf '%s' "$json" | jq -r '
            if type == "object" then
                (.tag_name // .name // empty)
            elif type == "array" and length > 0 then
                (.[0].tag_name // .[0].name // empty)
            else
                empty
            end' 2>/dev/null || true)
    fi

    # 2. Try python3 if installed
    if [ -z "$parsed_tag" ] && command -v python3 >/dev/null 2>&1; then
        parsed_tag=$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict):
        print(data.get("tag_name", "") or data.get("name", ""))
    elif isinstance(data, list) and len(data) > 0 and isinstance(data[0], dict):
        print(data[0].get("tag_name", "") or data[0].get("name", ""))
except Exception:
    pass
' 2>/dev/null || true)
    fi

    # 3. Try python if installed
    if [ -z "$parsed_tag" ] && command -v python >/dev/null 2>&1; then
        parsed_tag=$(printf '%s' "$json" | python -c '
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict):
        print(data.get("tag_name", "") or data.get("name", ""))
    elif isinstance(data, list) and len(data) > 0 and isinstance(data[0], dict):
        print(data[0].get("tag_name", "") or data[0].get("name", ""))
except Exception:
    pass
' 2>/dev/null || true)
    fi

    # 4. Safe POSIX awk parser
    if [ -z "$parsed_tag" ]; then
        parsed_tag=$(printf '%s' "$json" | awk -F'"' '
            /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "tag_name") { print $(i+2); exit }
                }
            }
        ' 2>/dev/null || true)
    fi

    parsed_tag=$(printf '%s' "$parsed_tag" | tr -d '\r\n[:space:]')
    if validate_tag "$parsed_tag"; then
        printf '%s' "$parsed_tag"
    fi
}

extract_redirect_tag() {
    local url="$1"
    local redirect_output=""
    redirect_output=$(curl -fsSI "$url" 2>/dev/null || true)
    [ -n "$redirect_output" ] || return 0

    local location_line=""
    location_line=$(printf '%s\n' "$redirect_output" | grep -i '^location:' | head -n1 || true)
    [ -n "$location_line" ] || return 0

    local loc=""
    loc=$(printf '%s' "$location_line" | sed -E 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//' | tr -d '\r\n[:space:]')

    case "$loc" in
        */releases/tag/*)
            local candidate="${loc##*/releases/tag/}"
            candidate="${candidate%%[/?#]*}"
            candidate=$(printf '%s' "$candidate" | tr -d '\r\n[:space:]')
            if validate_tag "$candidate"; then
                printf '%s' "$candidate"
                return 0
            fi
            ;;
        *)
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# 1. OS & Architecture Detection
# ------------------------------------------------------------------------------
printf "\n${BOLD}Installing %s...${NC}\n\n" "$APP_NAME"

OS="$(uname -s)"
info "Detecting operating system... $OS"
case "$OS" in
    Linux)
        OS_TYPE="linux"
        ;;
    Darwin)
        OS_TYPE="macos"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        OS_TYPE="windows"
        ;;
    *)
        fail "Unsupported operating system: $OS. MDM Desktop installer currently supports Linux, macOS, and Windows."
        ;;
esac

ARCH="$(uname -m)"
info "Detecting architecture... $ARCH"
case "$ARCH" in
    x86_64|amd64)
        ARCH_TYPE="x64"
        ;;
    arm64|aarch64)
        ARCH_TYPE="arm64"
        ;;
    *)
        fail "Unsupported CPU architecture: $ARCH. Supported architectures: x86_64 and arm64."
        ;;
esac

# ------------------------------------------------------------------------------
# 2. Version & Release Resolution
# ------------------------------------------------------------------------------
TAG=""

if [ -n "${MDM_VERSION:-}" ]; then
    if ! validate_tag "$MDM_VERSION"; then
        fail "Specified MDM_VERSION '$MDM_VERSION' is invalid.\nRelease tags must not contain spaces, colons, slashes, or control characters."
    fi
    TAG="$MDM_VERSION"
    info "Using explicitly requested version... $TAG"
else
    info "Finding latest release..."

    # Step 1: GitHub Releases API (/releases/latest)
    LATEST_API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    API_RESPONSE=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: MDM-Installer" "$LATEST_API_URL" 2>/dev/null || true)
    TAG=$(extract_json_tag "$API_RESPONSE")

    # Step 2: Fallback to Releases list API (/releases?per_page=1)
    if [ -z "$TAG" ]; then
        LIST_API_URL="https://api.github.com/repos/${REPO}/releases?per_page=1"
        LIST_RESPONSE=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: MDM-Installer" "$LIST_API_URL" 2>/dev/null || true)
        TAG=$(extract_json_tag "$LIST_RESPONSE")
    fi

    # Step 3: Fallback to releases/latest HTTP redirect
    if [ -z "$TAG" ]; then
        TAG=$(extract_redirect_tag "https://github.com/${REPO}/releases/latest")
    fi

    # Step 4: Fallback to Git Tags API (/tags)
    if [ -z "$TAG" ]; then
        TAGS_API_URL="https://api.github.com/repos/${REPO}/tags?per_page=15"
        TAGS_RESPONSE=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" -H "User-Agent: MDM-Installer" "$TAGS_API_URL" 2>/dev/null || true)
        if [ -n "$TAGS_RESPONSE" ]; then
            CANDIDATES=""
            if command -v jq >/dev/null 2>&1; then
                CANDIDATES=$(printf '%s' "$TAGS_RESPONSE" | jq -r '[.[] | select(.name | test("^v?[0-9]+\\.[0-9]+"))][].name' 2>/dev/null || true)
            elif command -v python3 >/dev/null 2>&1; then
                CANDIDATES=$(printf '%s' "$TAGS_RESPONSE" | python3 -c '
import sys, json, re
try:
    tags = json.load(sys.stdin)
    for t in tags:
        n = t.get("name", "")
        if re.match(r"^v?[0-9]+\.[0-9]+(\.[0-9]+)?.*$", n):
            print(n)
except Exception:
    pass
' 2>/dev/null || true)
            elif command -v python >/dev/null 2>&1; then
                CANDIDATES=$(printf '%s' "$TAGS_RESPONSE" | python -c '
import sys, json, re
try:
    tags = json.load(sys.stdin)
    for t in tags:
        n = t.get("name", "")
        if re.match(r"^v?[0-9]+\.[0-9]+(\.[0-9]+)?.*$", n):
            print(n)
except Exception:
    pass
' 2>/dev/null || true)
            fi

            for cand in $CANDIDATES; do
                if validate_tag "$cand"; then
                    cand_ver="${cand#v}"
                    cand_art=""
                    case "$OS_TYPE" in
                        linux) cand_art="MDM-${cand_ver}-linux-${ARCH_TYPE}.AppImage" ;;
                        macos) cand_art="MDM-${cand_ver}-macos-${ARCH_TYPE}.dmg" ;;
                        windows) cand_art="MDM-${cand_ver}-windows-${ARCH_TYPE}.exe" ;;
                    esac
                    if [ -n "$cand_art" ] && curl -fsSLI "https://github.com/${REPO}/releases/download/${cand}/${cand_art}" >/dev/null 2>&1; then
                        TAG="$cand"
                        break
                    fi
                fi
            done
        fi
    fi

    if [ -z "$TAG" ] || ! validate_tag "$TAG"; then
        fail "No published release was found for https://github.com/${REPO}.\n\nPlease check release status at:\n  https://github.com/${REPO}/releases"
    fi
fi

VERSION="${TAG#v}"

# Target desktop artifact name
DESKTOP_ARTIFACT=""
case "$OS_TYPE" in
    linux)
        DESKTOP_ARTIFACT="MDM-${VERSION}-linux-${ARCH_TYPE}.AppImage"
        ;;
    macos)
        DESKTOP_ARTIFACT="MDM-${VERSION}-macos-${ARCH_TYPE}.dmg"
        ;;
    windows)
        DESKTOP_ARTIFACT="MDM-${VERSION}-windows-${ARCH_TYPE}.exe"
        ;;
esac

if [ -z "$DESKTOP_ARTIFACT" ]; then
    fail "No desktop package format configured for ${OS_TYPE}-${ARCH_TYPE}."
fi

info "Selected release: $TAG"
info "Target package: $DESKTOP_ARTIFACT"

# ------------------------------------------------------------------------------
# 3. Secure Temporary Download
# ------------------------------------------------------------------------------
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'mdm-install')
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

DEFAULT_BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
BASE_URL="${MDM_BASE_URL:-$DEFAULT_BASE_URL}"

PACKAGE_URL="${BASE_URL}/${DESKTOP_ARTIFACT}"
CHECKSUM_URL="${BASE_URL}/checksums.txt"
CHECKSUM_FALLBACK_URL="${BASE_URL}/SHA256SUMS"

# Verify artifact existence before downloading
if [ -z "${MDM_BASE_URL:-}" ]; then
    if ! curl -fsSLI "$PACKAGE_URL" >/dev/null 2>&1; then
        fail "Desktop package '${DESKTOP_ARTIFACT}' was not found in release ${TAG}.\nURL checked: ${PACKAGE_URL}\n\nPlease check available packages at:\n  https://github.com/${REPO}/releases/tag/${TAG}"
    fi
fi

info "Downloading ${APP_NAME} (${DESKTOP_ARTIFACT})..."
if ! curl -fSL "$PACKAGE_URL" -o "${TMP_DIR}/${DESKTOP_ARTIFACT}"; then
    fail "Failed to download package from: ${PACKAGE_URL}"
fi

info "Fetching cryptographic checksums..."
if ! curl -fsSL "$CHECKSUM_URL" -o "${TMP_DIR}/checksums.txt" 2>/dev/null; then
    if ! curl -fsSL "$CHECKSUM_FALLBACK_URL" -o "${TMP_DIR}/checksums.txt" 2>/dev/null; then
        fail "Failed to retrieve cryptographic checksum file from release ${TAG}."
    fi
fi

# ------------------------------------------------------------------------------
# 4. Cryptographic SHA-256 Verification
# ------------------------------------------------------------------------------
info "Verifying SHA-256 checksum..."

EXPECTED_HASH=$(grep -E "[[:space:]]${DESKTOP_ARTIFACT}$" "${TMP_DIR}/checksums.txt" 2>/dev/null | head -n1 | awk '{print $1}' || true)
if [ -z "$EXPECTED_HASH" ]; then
    EXPECTED_HASH=$(grep -E "[[:space:]](\*|\./)?${DESKTOP_ARTIFACT}$" "${TMP_DIR}/checksums.txt" 2>/dev/null | head -n1 | awk '{print $1}' || true)
fi

if [ -z "$EXPECTED_HASH" ]; then
    fail "Checksum file does not contain an entry for ${DESKTOP_ARTIFACT}."
fi

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_HASH=$(sha256sum "${TMP_DIR}/${DESKTOP_ARTIFACT}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_HASH=$(shasum -a 256 "${TMP_DIR}/${DESKTOP_ARTIFACT}" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
    ACTUAL_HASH=$(openssl dgst -sha256 "${TMP_DIR}/${DESKTOP_ARTIFACT}" | awk '{print $NF}')
else
    fail "No SHA-256 verification tool found (requires sha256sum, shasum, or openssl)."
fi

EXPECTED_HASH=$(printf "%s" "$EXPECTED_HASH" | tr '[:upper:]' '[:lower:]')
ACTUAL_HASH=$(printf "%s" "$ACTUAL_HASH" | tr '[:upper:]' '[:lower:]')

if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
    fail "The downloaded package failed SHA-256 verification.\nExpected: ${EXPECTED_HASH}\nActual:   ${ACTUAL_HASH}"
fi

success "Checksum verified: ${ACTUAL_HASH}"

# ------------------------------------------------------------------------------
# 5. Desktop Application Installation
# ------------------------------------------------------------------------------
INSTALLED_LOCATION=""

if [ "$OS_TYPE" = "linux" ]; then
    APPS_DIR="${HOME}/Applications"
    mkdir -p "$APPS_DIR" "$BIN_DIR"
    APPIMAGE_TARGET="${APPS_DIR}/${DESKTOP_ARTIFACT}"
    APPIMAGE_SYMLINK="${APPS_DIR}/MDM.AppImage"

    info "Installing Desktop AppImage to ${APPIMAGE_TARGET}..."
    rm -f "$APPIMAGE_TARGET"
    cp "${TMP_DIR}/${DESKTOP_ARTIFACT}" "$APPIMAGE_TARGET"
    chmod +x "$APPIMAGE_TARGET"
    ln -sf "$APPIMAGE_TARGET" "$APPIMAGE_SYMLINK"
    ln -sf "$APPIMAGE_TARGET" "${BIN_DIR}/${BIN_NAME}" 2>/dev/null || true
    INSTALLED_LOCATION="$APPIMAGE_TARGET"

    # Install high-resolution application icon
    ICON_DIR="${HOME}/.local/share/icons/hicolor/128x128/apps"
    mkdir -p "$ICON_DIR"
    ICON_PATH="${ICON_DIR}/mdm.png"
    if [ ! -f "$ICON_PATH" ]; then
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/assets/128x128.png" -o "$ICON_PATH" 2>/dev/null || true
    fi

    # Install desktop application menu launcher
    MENU_DIR="${HOME}/.local/share/applications"
    mkdir -p "$MENU_DIR"
    DESKTOP_ENTRY="${MENU_DIR}/mdm.desktop"
    cat <<EOF > "$DESKTOP_ENTRY"
[Desktop Entry]
Name=MDM Download Manager
GenericName=Download Manager
Comment=Fast, reliable, local-first download manager
Exec=${APPIMAGE_TARGET} %U
Icon=mdm
Terminal=false
Type=Application
Categories=Network;FileTransfer;
StartupWMClass=mdm-desktop
MimeType=x-scheme-handler/mdm;
EOF
    chmod +x "$DESKTOP_ENTRY"

    # Also place on Desktop if ~/Desktop exists
    if [ -d "${HOME}/Desktop" ]; then
        cp "$DESKTOP_ENTRY" "${HOME}/Desktop/mdm.desktop" 2>/dev/null || true
        chmod +x "${HOME}/Desktop/mdm.desktop" 2>/dev/null || true
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$MENU_DIR" 2>/dev/null || true
    fi

elif [ "$OS_TYPE" = "macos" ]; then
    info "Installing Desktop App to /Applications..."
    MOUNT_POINT=$(mktemp -d 2>/dev/null || mktemp -d -t 'mdm-dmg')
    if hdiutil attach "${TMP_DIR}/${DESKTOP_ARTIFACT}" -mountpoint "$MOUNT_POINT" -nobrowse -quiet; then
        APP_SRC=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.app" 2>/dev/null | head -n1 || true)
        if [ -n "$APP_SRC" ]; then
            DEST_APP="/Applications/$(basename "$APP_SRC")"
            if [ ! -w "/Applications" ]; then
                mkdir -p "${HOME}/Applications"
                DEST_APP="${HOME}/Applications/$(basename "$APP_SRC")"
            fi
            rm -rf "$DEST_APP"
            cp -R "$APP_SRC" "$DEST_APP"
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
            rm -rf "$MOUNT_POINT"
            INSTALLED_LOCATION="$DEST_APP"

            # Symlink command to launch from terminal
            mkdir -p "$BIN_DIR"
            APP_BIN=$(find "${DEST_APP}/Contents/MacOS" -type f -perm +111 2>/dev/null | head -n1 || true)
            if [ -n "$APP_BIN" ]; then
                ln -sf "$APP_BIN" "${BIN_DIR}/${BIN_NAME}" 2>/dev/null || true
            fi
        else
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
            rm -rf "$MOUNT_POINT"
            fail "Could not find .app bundle inside macOS disk image."
        fi
    else
        rm -rf "$MOUNT_POINT"
        fail "Could not mount disk image ${DESKTOP_ARTIFACT}."
    fi
elif [ "$OS_TYPE" = "windows" ]; then
    info "Running MDM Windows Installer..."
    cmd.exe /c start "" /wait "${TMP_DIR}/${DESKTOP_ARTIFACT}" /S
    INSTALLED_LOCATION="C:\\Program Files\\MDM Download Manager"
fi

# ------------------------------------------------------------------------------
# 6. PATH Environment Configuration
# ------------------------------------------------------------------------------
PATH_UPDATED=0
case ":$PATH:" in
    *":$BIN_DIR:"*)
        ;;
    *)
        EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
        SHELL_NAME="$(basename "${SHELL:-bash}")"
        PROFILE_FILE=""

        if [ "$SHELL_NAME" = "zsh" ]; then
            PROFILE_FILE="${HOME}/.zshrc"
        elif [ "$SHELL_NAME" = "bash" ]; then
            if [ "$OS_TYPE" = "macos" ] && [ -f "${HOME}/.bash_profile" ]; then
                PROFILE_FILE="${HOME}/.bash_profile"
            else
                PROFILE_FILE="${HOME}/.bashrc"
            fi
        else
            PROFILE_FILE="${HOME}/.profile"
        fi

        if [ -n "$PROFILE_FILE" ]; then
            if [ ! -f "$PROFILE_FILE" ] || ! grep -qs "${BIN_DIR}" "$PROFILE_FILE"; then
                printf "\n# MDM Download Manager\n%s\n" "$EXPORT_LINE" >> "$PROFILE_FILE"
                PATH_UPDATED=1
            fi
        fi
        ;;
esac

# ------------------------------------------------------------------------------
# 6.5 Native Messaging Host Registration + Browser Integration (optional)
# ------------------------------------------------------------------------------
# The MDM browser extension talks to the desktop app through a native messaging
# host named com.mdm.native_host. The extension ID is deterministic (derived from
# the committed manifest key), so registration no longer requires pasting the ID
# shown at chrome://extensions — the installer can configure the host now.
#
# Control:
#   MDM_BROWSER_SETUP=none   Skip the browser integration entirely
#   MDM_EXTENSION_ID=xxxx    Override the stable extension ID (custom builds)
DEFAULT_BROWSER_EXT_ID="jlhjhpchnlpgbgdcaniadhapcldphhae"

setup_native_host() {
    local ext_id="${1:-$DEFAULT_BROWSER_EXT_ID}"
    local suffix=""
    [ "$OS_TYPE" = "windows" ] && suffix=".exe"
    local cli_dir="${HOME}/.local/share/mdm/bin"
    local cli_bin="${cli_dir}/mdm${suffix}"
    local host_bin="${cli_dir}/mdm-native-host${suffix}"
    local cli_artifact="mdm-${OS_TYPE}-${ARCH_TYPE}${suffix}"
    local host_artifact="mdm-native-host-${OS_TYPE}-${ARCH_TYPE}${suffix}"

    if [ ! -x "$cli_bin" ] || [ ! -x "$host_bin" ]; then
        mkdir -p "$cli_dir"
        info "Fetching MDM CLI & native messaging host binary ($TAG)..."
        if ! curl -fSL "${BASE_URL}/${cli_artifact}" -o "$cli_bin" 2>/dev/null ||
           ! verify_sha256 "$cli_bin" "$cli_artifact"; then
            warn "Could not fetch/verify the MDM CLI; native host registration deferred."
            rm -f "$cli_bin"
            return 1
        fi
        if ! curl -fSL "${BASE_URL}/${host_artifact}" -o "$host_bin" 2>/dev/null ||
           ! verify_sha256 "$host_bin" "$host_artifact"; then
            warn "Could not fetch/verify the native messaging host; registration deferred."
            rm -f "$cli_bin" "$host_bin"
            return 1
        fi
        chmod +x "$cli_bin" "$host_bin"
    fi

    info "Registering native messaging host for extension ID '${ext_id}'..."
    if [ "$ext_id" = "$DEFAULT_BROWSER_EXT_ID" ]; then
        if "$cli_bin" register-browser-host --binary-path "$host_bin"; then
            success "Native messaging host registered for stable extension ID '${ext_id}'."
        else
            warn "Native host registration command failed. Run later with:"
            printf "    %s register-browser-host --binary-path %s\n" "$cli_bin" "$host_bin"
        fi
    else
        if "$cli_bin" register-browser-host --binary-path "$host_bin" --extension-id "$ext_id"; then
            success "Native messaging host registered for extension ID '${ext_id}'."
        else
            warn "Native host registration command failed. Run later with:"
            printf "    %s register-browser-host --binary-path %s --extension-id %s\n" "$cli_bin" "$host_bin" "$ext_id"
        fi
    fi
}

EXTENSION_ID=""
if [ "${MDM_BROWSER_SETUP:-}" = "none" ]; then
    EXTENSION_ID="__skip__"
elif [ -n "${MDM_EXTENSION_ID:-}" ]; then
    EXTENSION_ID="$(printf '%s' "$MDM_EXTENSION_ID" | tr -d '\r\n[:space:]')"
elif [ "${MDM_BROWSER_SETUP:-}" = "auto" ]; then
    EXTENSION_ID=""  # non-interactive opt-in: auto (deterministic default)
elif [ -t 0 ]; then
    printf "\n${BOLD}Browser integration (optional)${NC}\n"
    printf "MDM registers a native messaging host for its browser extension so\n"
    printf "downloads can be intercepted from Chrome, Edge, Brave, Chromium, and\n"
    printf "Firefox. This downloads the small CLI + host binaries and configures\n"
    printf "the extension automatically (no ID to look up).\n"
    printf "${CYAN}  Set up browser integration now? [Y/n]${NC} "
    read -r answer || true
    case "$answer" in
        n|N|no) EXTENSION_ID="__skip__" ;;
        *) EXTENSION_ID="" ;;  # auto (deterministic default)
    esac
else
    EXTENSION_ID="__skip__"
fi

if [ "$EXTENSION_ID" = "__skip__" ]; then
    info "Skipping browser integration setup. Register later with:"
    printf "    %s/.local/bin/mdm register-browser-host\n" "$HOME"
elif [ -z "$EXTENSION_ID" ]; then
    setup_native_host "$DEFAULT_BROWSER_EXT_ID"
elif [[ "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
    setup_native_host "$EXTENSION_ID"
else
    warn "Invalid extension ID '${EXTENSION_ID}' ignored. Using the stable MDM ID."
    setup_native_host "$DEFAULT_BROWSER_EXT_ID"
fi

# ------------------------------------------------------------------------------
# 7. Completion & Launch Instructions
# ------------------------------------------------------------------------------
printf "\n"
success "${BOLD}${APP_NAME} (${TAG}) installed successfully!${NC}\n"

printf "${BOLD}Installation Details:${NC}\n"
printf "  Application: ${CYAN}%s${NC}\n" "$INSTALLED_LOCATION"
if [ "$OS_TYPE" = "linux" ]; then
    printf "  Shortcuts:   ${CYAN}Application Menu${NC} & ${CYAN}~/Desktop/mdm.desktop${NC}\n"
fi
printf "  Terminal:    ${CYAN}%s/%s${NC}\n\n" "$BIN_DIR" "$BIN_NAME"

printf "Launch with:\n"
if [ "$OS_TYPE" = "linux" ]; then
    printf "  - Click ${BOLD}MDM Download Manager${NC} in your Application Menu or Desktop\n"
    printf "  - Or run: ${BOLD}mdm${NC}\n\n"
elif [ "$OS_TYPE" = "macos" ]; then
    printf "  - Open ${BOLD}MDM Download Manager${NC} from Applications or Spotlight\n"
    printf "  - Or run: ${BOLD}mdm${NC}\n\n"
fi

printf "${BOLD}Browser extension:${NC}\n"
printf "  - After opening MDM, use Settings ${CYAN}D. Browser Integration${NC} (or\n"
printf "    ${CYAN}mdm browser-extension install${NC}) to copy the extension and register the\n"
printf "    native messaging host automatically.\n"
printf "  - Then enable Developer mode at ${CYAN}chrome://extensions${NC} and choose\n"
printf "    ${CYAN}Load unpacked${NC} → .local/share/mdm/browser-extension.\n\n"
