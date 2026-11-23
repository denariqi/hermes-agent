
#!/bin/bash
# Build Hermes Desktop for Intel macOS and package it as a verified DMG.
# Output: dist/Hermes-<version>-mac-x64.dmg

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 0. Configuration
# ============================================================

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-$HERMES_HOME/hermes-agent}"
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"

APP=""
STAGE=""
MOUNT_POINT=""
TEMP_DMG=""
FINAL_DMG=""
MOUNTED=0

log() {
    echo
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local status=$?

    if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi

    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$TEMP_DMG" ] || rm -f "$TEMP_DMG"

    if [ "$status" -ne 0 ]; then
        echo
        echo "Build failed. Exit code: $status" >&2
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# 1. Environment validation
# ============================================================

log "Checking build environment..."

[ "$(uname -s)" = "Darwin" ] || die "This script requires macOS."

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || {
    die "Intel Mac required. Current architecture: $ARCH"
}

for cmd in curl bash file grep find git hdiutil \
           shasum lipo ditto mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

[ -n "$HOME" ] || die "HOME is empty."
[ -d "$REPO_ROOT" ] || die "Repository directory not found."

mkdir -p "$DIST_DIR"

AVAILABLE_SPACE="$(df -Pk "$DIST_DIR" | awk 'NR==2 {print $4}')"
[ -n "$AVAILABLE_SPACE" ] || die "Cannot determine free disk space."

[ "$AVAILABLE_SPACE" -ge 2097152 ] || \
    die "At least 2 GB free disk space is recommended."

log "Intel architecture confirmed."
echo "Repository: $REPO_ROOT"
echo "Install dir: $INSTALL_DIR"

# ============================================================
# 2. Install / update Hermes CLI
# ============================================================

log "Installing or updating Hermes CLI..."

curl -fsSL \
    https://hermes-agent.nousresearch.com/install.sh |
    bash -s -- --skip-setup

[ -x "$HERMES_BIN" ] || \
    die "Hermes CLI not found or not executable: $HERMES_BIN"

log "Hermes CLI version..."

VERSION_OUTPUT="$("$HERMES_BIN" --version 2>&1)" || \
    die "Cannot retrieve Hermes CLI version."

VERSION="$(printf '%s\n' "$VERSION_OUTPUT" |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
    head -1 || true)"

[ -n "$VERSION" ] || \
    die "Unable to parse Hermes version: $VERSION_OUTPUT"

echo "Version: $VERSION"

[ -d "$INSTALL_DIR" ] || \
    die "Hermes installation directory not found: $INSTALL_DIR"

COMMIT="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)" || \
    die "Cannot determine upstream Git commit."

# ============================================================
# 3. Build Desktop x64
# ============================================================

log "Building Hermes Desktop..."

"$HERMES_BIN" desktop --build-only --force-build

# ============================================================
# 4. Locate application bundle
# ============================================================

log "Locating Hermes.app..."

for candidate in \
    "$INSTALL_DIR/apps/desktop/release/mac/Hermes.app" \
    "$INSTALL_DIR/apps/desktop/release/mac-x64/Hermes.app"; do

    if [ -d "$candidate" ]; then
        APP="$candidate"
        break
    fi
done

[ -n "$APP" ] || die "Hermes.app was not generated."

MAIN_BINARY="$APP/Contents/MacOS/Hermes"

[ -f "$MAIN_BINARY" ] || \
    die "Main executable not found: $MAIN_BINARY"

[ -x "$MAIN_BINARY" ] || \
    die "Main executable is not executable."

# ============================================================
# 5. Architecture verification
# ============================================================

log "Checking application architecture..."

APP_ARCHS="$(lipo -archs "$MAIN_BINARY" 2>/dev/null)" || \
    die "Cannot inspect application architecture."

echo "Detected architectures: $APP_ARCHS"

case " $APP_ARCHS " in
    *" x86_64 "*) ;;
    *) die "Application does not contain x86_64 architecture." ;;
esac

# ============================================================
# 6. Bundle integrity checks
# ============================================================

log "Checking application bundle..."

[ -f "$APP/Contents/Info.plist" ] || \
    die "Info.plist missing."

/usr/libexec/PlistBuddy \
    -c "Print :CFBundleExecutable" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
    die "Invalid application Info.plist."

# ============================================================
# 7. Privacy and secret scanning
# ============================================================

log "Scanning for personal paths and possible leaked secrets..."

scan_pattern() {
    local description="$1"
    local pattern="$2"
    local matches

    matches="$(grep -aRIlE -- "$pattern" "$APP" 2>/dev/null || true)"

    if [ -n "$matches" ]; then
        echo "Potential leak: $description" >&2
        echo "$matches" >&2
        die "Privacy scan failed."
    fi
}

# Personal home directory
if grep -aRIlF -- "$HOME" "$APP" 2>/dev/null | grep -q .; then
    die "Bundle contains references to personal HOME path."
fi

# Private keys
scan_pattern "Private key" \
    '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'

# Common API token patterns
scan_pattern "Possible GitHub token" \
    'gh[pousr]_[A-Za-z0-9_]{30,}'

scan_pattern "Possible AWS access key" \
    'AKIA[0-9A-Z]{16}'

scan_pattern "Possible OpenAI-style secret" \
    'sk-[A-Za-z0-9_-]{30,}'

log "Privacy scan passed."

# ============================================================
# 8. Prepare DMG staging directory
# ============================================================

log "Preparing DMG staging directory..."

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-stage.XXXXXX")"

# ditto preserves macOS application bundle metadata
ditto "$APP" "$STAGE/Hermes.app"

ln -s /Applications "$STAGE/Applications"

# ============================================================
# 9. Create DMG
# ============================================================

log "Creating DMG..."

FINAL_DMG="$DIST_DIR/Hermes-$VERSION-mac-x64.dmg"
TEMP_DMG="$DIST_DIR/.Hermes-$VERSION-mac-x64.tmp.dmg"

rm -f "$TEMP_DMG"

hdiutil create \
    -volname "Hermes (Intel)" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$TEMP_DMG"

[ -s "$TEMP_DMG" ] || die "DMG creation failed."

# ============================================================
# 10. DMG verification
# ============================================================

log "Verifying DMG image..."

hdiutil verify "$TEMP_DMG" || \
    die "DMG verification failed."

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/hermes-mount.XXXXXX")"

hdiutil attach \
    "$TEMP_DMG" \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_POINT" >/dev/null

MOUNTED=1

[ -d "$MOUNT_POINT/Hermes.app" ] || \
    die "Hermes.app missing inside DMG."

[ -L "$MOUNT_POINT/Applications" ] || \
    die "Applications symlink missing inside DMG."

[ -x "$MOUNT_POINT/Hermes.app/Contents/MacOS/Hermes" ] || \
    die "DMG application executable invalid."

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

rmdir "$MOUNT_POINT"
MOUNT_POINT=""

log "DMG verification passed."

# ============================================================
# 11. Publish final artifact
# ============================================================

log "Publishing final DMG..."

mv -f "$TEMP_DMG" "$FINAL_DMG"
TEMP_DMG=""

shasum -a 256 "$FINAL_DMG" > "$FINAL_DMG.sha256"

# ============================================================
# 12. Build report
# ============================================================

echo
echo "=========================================="
echo " Hermes Desktop Intel Build Completed"
echo "=========================================="
echo "Version : $VERSION"
echo "Commit  : $COMMIT"
echo "Arch    : $APP_ARCHS"
echo "DMG     : $FINAL_DMG"
echo "SHA256  : $(awk '{print $1}' FINAL_DMG.sha256"
echo "=========================================="
