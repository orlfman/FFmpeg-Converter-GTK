#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/builddir-debug"
BINARY_NAME="ffmpeg-converter-gtk"

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Error: '$1' is not installed. Please install it and try again."
        exit 1
    fi
}

echo "=== FFmpeg Converter GTK - DEBUG Build ==="
echo "Detected project directory: $PROJECT_DIR"
echo

# --- Dependency checks ---
echo "Checking required tools..."
check_dependency meson
check_dependency ninja
check_dependency valac
check_dependency pkg-config
check_dependency gdb
echo "✅ All dependencies found"
echo

# --- Clean debug build ---
if [ -d "$BUILD_DIR" ]; then
    echo "🧹 Removing old debug build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "🔧 Running meson setup (debug mode)..."
if ! meson setup "$BUILD_DIR" --buildtype=debug -Db_sanitize=address; then
    echo "⚠️  ASan not available, retrying without sanitizer..."
    rm -rf "$BUILD_DIR"
    if ! meson setup "$BUILD_DIR" --buildtype=debug; then
        echo "❌ Meson setup failed"
        exit 1
    fi
fi

echo "⚙️  Compiling with debug symbols..."
if ! meson compile -C "$BUILD_DIR"; then
    echo "❌ Build failed"
    exit 1
fi

if [ ! -f "$BUILD_DIR/$BINARY_NAME" ]; then
    echo "❌ Error: Binary '$BINARY_NAME' was not created in $BUILD_DIR"
    exit 1
fi
echo "✅ Debug build successful!"
echo

# --- Run under GDB ---
echo "========================================"
echo "  Launching under GDB"
echo ""
echo "  When it crashes, GDB will catch it."
echo "  Type:  bt        (full backtrace)"
echo "         bt full   (with local variables)"
echo "         quit      (to exit)"
echo "========================================"
echo

gdb -ex "set pagination off" \
    -ex "run" \
    -ex "echo \n=== CRASHED ===\n\n" \
    -ex "bt" \
    -ex "echo \n=== FULL BACKTRACE WITH LOCALS ===\n\n" \
    -ex "bt full" \
    -ex "echo \n=== THREAD INFO ===\n\n" \
    -ex "info threads" \
    -ex "echo \nType 'quit' to exit or explore further.\n" \
    "$BUILD_DIR/$BINARY_NAME"
