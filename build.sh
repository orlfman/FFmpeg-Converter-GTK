#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/builddir"
BINARY_NAME="ffmpeg-converter-gtk"
INSTALL_DIR="/usr/local/bin"

DESKTOP_SOURCE="$PROJECT_DIR/FFmpegConverterGTK.desktop"
DESKTOP_DEST="/usr/share/applications/ffmpeg-converter-gtk.desktop"
ICON_SOURCE="$PROJECT_DIR/ffmpeg-converter-gtk.svg"
ICON_DEST="/usr/share/icons/hicolor/scalable/apps/ffmpeg-converter-gtk.svg"

# Track what was installed for summary
declare -a installed_items=()
declare -a skipped_items=()

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Error: '$1' is not installed. Please install it and try again."
        exit 1
    fi
}

# Returns 0 if files are identical, 1 if they differ or dest is missing
files_match() {
    local source="$1"
    local dest="$2"

    [ ! -e "$dest" ] && return 1
    [ ! -e "$source" ] && return 1

    local source_sha dest_sha
    source_sha=$(sha256sum "$source" | awk '{print $1}')
    dest_sha=$(sha256sum "$dest" | awk '{print $1}')

    [ "$source_sha" = "$dest_sha" ]
}

# Returns 0 if we should proceed with install, 1 to skip
ask_upgrade() {
    local dest="$1"
    local name="$2"
    local source="$3"

    if [ ! -e "$dest" ]; then
        echo "→ No $name found on system — installing fresh"
        return 0
    fi

    if files_match "$source" "$dest"; then
        echo "→ $name is already up to date — nothing to do"
        skipped_items+=("$name (up to date)")
        return 1
    fi

    echo "→ New version of $name available!"
    read -p "  Upgrade? [Y/n] " -n 1 -r REPLY
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "  → Skipping $name"
        skipped_items+=("$name (user skipped)")
        return 1
    fi
    return 0
}

# Verify sudo access before we start installing
check_sudo() {
    if ! sudo -v 2>/dev/null; then
        echo "❌ Error: sudo access is required for installation."
        exit 1
    fi
}

echo "=== FFmpeg Converter GTK - Clean Fresh Build & Install ==="
echo "Detected project directory: $PROJECT_DIR"
echo

# --- Dependency checks ---
echo "Checking required tools..."
check_dependency meson
check_dependency ninja
check_dependency valac
check_dependency pkg-config
echo "✅ All dependencies found"
echo

# --- Clean build ---
if [ -d "$BUILD_DIR" ]; then
    echo "🧹 Removing old build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "🔧 Running meson setup..."
if ! meson setup "$BUILD_DIR"; then
    echo "❌ Meson setup failed"
    exit 1
fi

echo "⚙️  Compiling..."
if ! meson compile -C "$BUILD_DIR"; then
    echo "❌ Build failed"
    exit 1
fi

if [ ! -f "$BUILD_DIR/$BINARY_NAME" ]; then
    echo "❌ Error: Binary '$BINARY_NAME' was not created in $BUILD_DIR"
    exit 1
fi
echo "✅ Build successful!"
echo

# --- Installation ---
echo "Preparing to install (sudo may be required)..."
check_sudo

# Binary
if ask_upgrade "$INSTALL_DIR/$BINARY_NAME" "binary" "$BUILD_DIR/$BINARY_NAME"; then
    echo "  Installing binary..."
    if sudo install -m 755 "$BUILD_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"; then
        echo "  ✅ Binary installed"
        installed_items+=("binary")
    else
        echo "  ❌ Failed to install binary"
        exit 1
    fi
fi

# Icon
if [ -f "$ICON_SOURCE" ]; then
    if ask_upgrade "$ICON_DEST" "application icon" "$ICON_SOURCE"; then
        echo "  Installing icon..."
        sudo mkdir -p "$(dirname "$ICON_DEST")"
        if sudo install -m 644 "$ICON_SOURCE" "$ICON_DEST"; then
            sudo gtk-update-icon-cache /usr/share/icons/hicolor -q 2>/dev/null || true
            echo "  ✅ Icon installed"
            installed_items+=("icon")
        else
            echo "  ❌ Failed to install icon"
        fi
    fi
else
    echo "⚠️  Warning: Icon not found at $ICON_SOURCE — skipping"
fi

# Desktop entry
if [ -f "$DESKTOP_SOURCE" ]; then
    if ask_upgrade "$DESKTOP_DEST" ".desktop entry" "$DESKTOP_SOURCE"; then
        echo "  Installing desktop entry..."
        if sudo install -m 644 "$DESKTOP_SOURCE" "$DESKTOP_DEST"; then
            sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
            echo "  ✅ Desktop entry installed"
            installed_items+=("desktop entry")
        else
            echo "  ❌ Failed to install desktop entry"
        fi
    fi
else
    echo "⚠️  Warning: .desktop file not found at $DESKTOP_SOURCE — skipping"
fi

# --- Summary ---
echo
echo "========================================"
if [ ${#installed_items[@]} -gt 0 ]; then
    echo "✅ Installed: ${installed_items[*]}"
fi
if [ ${#skipped_items[@]} -gt 0 ]; then
    echo "⏭️  Skipped:   ${skipped_items[*]}"
fi
echo
echo "Run with: $BINARY_NAME"
echo "or search for 'FFmpeg Converter GTK' in your menu."
echo "========================================"
