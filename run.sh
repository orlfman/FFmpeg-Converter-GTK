#!/bin/bash
echo "=== FFmpeg Converter GTK ==="

if [ -f "builddir/ffmpeg-converter-gtk" ]; then
    echo "🚀 Launching app..."
    ./builddir/ffmpeg-converter-gtk
else
    echo "❌ Executable not found. Run ./build.sh first."
fi
