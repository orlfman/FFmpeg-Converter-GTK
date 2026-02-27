#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/builddir"
BINARY_NAME="ffmpeg-converter-gtk"
INSTALL_DIR="/usr/local/bin"

# Use the exact files you have in your folder
DESKTOP_SOURCE="$PROJECT_DIR/FFmpegConverterGTK.desktop"
DESKTOP_DEST="/usr/share/applications/ffmpeg-converter-gtk.desktop"
ICON_SOURCE="$PROJECT_DIR/ffmpeg-converter-gtk.svg"
ICON_DEST="/usr/share/icons/hicolor/scalable/apps/ffmpeg-converter-gtk.svg"

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Error: $1 is not installed. Please install it and try again."
        exit 1
    fi
}

check_sha() {
    local source="$1"
    local dest="$2"
    [ ! -e "$dest" ] && return 1
    source_sha=$(sha256sum "$source" | awk '{print $1}')
    dest_sha=$(sha256sum "$dest" | awk '{print $1}')
    [ "$source_sha" != "$dest_sha" ]
}

ask_upgrade() {
    local path="$1"
    local name="$2"
    local source="$3"
    if [ ! -e "$path" ]; then
        echo "→ No $name found on system — installing fresh"
        return 0
    fi
    if ! check_sha "$source" "$path"; then
        echo "→ $name is already up to date — nothing to do"
        return 1
    fi
    echo "→ New version of $name available!"
    read -p "Upgrade? [Y/n] " -n 1 -r REPLY
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "→ Skipping $name"
        return 1
    else
        return 0
    fi
}

echo "=== FFmpeg Converter GTK - Clean Fresh Build & Install ==="
echo "Detected project directory: $PROJECT_DIR"

# Dependency checks
echo "Checking required tools..."
check_dependency meson
check_dependency ninja
check_dependency valac
check_dependency pkg-config

# Clean build
if [ -d "$BUILD_DIR" ]; then
    echo "🧹 Removing old build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "🔧 Running meson setup..."
meson setup "$BUILD_DIR" || { echo "❌ Meson setup failed"; exit 1; }

echo "⚙️ Compiling..."
meson compile -C "$BUILD_DIR" || { echo "❌ Build failed"; exit 1; }

if [ ! -f "$BUILD_DIR/$BINARY_NAME" ]; then
    echo "❌ Error: Binary '$BINARY_NAME' was not created."
    exit 1
fi

echo "✅ Build successful!"

# ── Smart Installation ─────────────────────────────────────────────────────

if ask_upgrade "$INSTALL_DIR/$BINARY_NAME" "binary" "$BUILD_DIR/$BINARY_NAME"; then
    echo "Installing binary..."
    sudo cp "$BUILD_DIR/$BINARY_NAME" "$INSTALL_DIR/" && \
    sudo chmod 755 "$INSTALL_DIR/$BINARY_NAME"
fi

if [ -f "$ICON_SOURCE" ]; then
    if ask_upgrade "$ICON_DEST" "application icon" "$ICON_SOURCE"; then
        echo "Installing icon..."
        sudo mkdir -p "$(dirname "$ICON_DEST")"
        sudo cp "$ICON_SOURCE" "$ICON_DEST"
        sudo gtk-update-icon-cache /usr/share/icons/hicolor -q 2>/dev/null || true
        echo "✅ Icon installed"
    fi
else
    echo "⚠️ Warning: Icon not found at $ICON_SOURCE"
fi

if [ -f "$DESKTOP_SOURCE" ]; then
    if ask_upgrade "$DESKTOP_DEST" ".desktop entry" "$DESKTOP_SOURCE"; then
        echo "Installing desktop entry..."
        sudo cp "$DESKTOP_SOURCE" "$DESKTOP_DEST"
        sudo chmod 644 "$DESKTOP_DEST"
        sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
        echo "✅ Desktop entry installed"
    fi
else
    echo "⚠️ Warning: .desktop file not found at $DESKTOP_SOURCE"
fi

echo
echo "========================================"
echo "✅ Build and installation completed!"
echo "Run with: $BINARY_NAME"
echo "or search for 'FFmpeg Converter GTK' in your menu."
echo "========================================"
