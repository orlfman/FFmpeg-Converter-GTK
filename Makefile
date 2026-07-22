# FFmpeg Converter GTK - Makefile
# Wrapper around Meson for release-oriented app builds.
# Tests are opt-in via `make test` and are not compiled by default.

BUILDDIR    := builddir
BINARY      := ffmpeg-converter-gtk
PREFIX      := /usr
DATADIR     := $(PREFIX)/share
ICONDIR     := $(DATADIR)/icons/hicolor/scalable/apps
DESKTOPDIR  := $(DATADIR)/applications

.PHONY: all setup build test install uninstall clean rebuild help

all: build

setup:
	@command -v meson >/dev/null  || { echo "Error: meson is not installed";    exit 1; }
	@command -v ninja >/dev/null  || { echo "Error: ninja is not installed";    exit 1; }
	@command -v valac >/dev/null  || { echo "Error: valac is not installed";    exit 1; }
	@command -v pkg-config >/dev/null || { echo "Error: pkg-config is not installed"; exit 1; }
	@pkg-config --exists gtk4 || { echo "Error: gtk4 development files are not installed"; exit 1; }
	@pkg-config --exists libadwaita-1 || { echo "Error: libadwaita-1 development files are not installed"; exit 1; }
	@pkg-config --exists json-glib-1.0 || { echo "Error: json-glib-1.0 development files are not installed"; exit 1; }
	@command -v ffmpeg >/dev/null || { echo "Error: ffmpeg is not installed"; exit 1; }
	@command -v ffprobe >/dev/null || { echo "Error: ffprobe is not installed"; exit 1; }
	@command -v gst-inspect-1.0 >/dev/null || { echo "Error: GStreamer runtime tools are not installed (missing gst-inspect-1.0)"; exit 1; }
	@if [ ! -d $(BUILDDIR) ]; then \
		meson setup $(BUILDDIR) --prefix=$(PREFIX); \
	else \
		meson setup $(BUILDDIR) --reconfigure --prefix=$(PREFIX); \
	fi

build: setup
	meson compile -C $(BUILDDIR)

test: build
	meson test -C $(BUILDDIR)

install: build
	@if command -v pacman >/dev/null 2>&1 && pacman -Qo $(PREFIX)/bin/$(BINARY) >/dev/null 2>&1; then \
		pacman -Qo $(PREFIX)/bin/$(BINARY); \
		echo "Refusing to overwrite package-managed files."; \
		echo "Use 'yay -S ffmpeg-converter-gtk' for installs, or remove the package first:"; \
		echo "    sudo pacman -R ffmpeg-converter-gtk"; \
		exit 1; \
	fi
	sudo meson install -C $(BUILDDIR)
	@if [ -f /usr/local/bin/$(BINARY) ]; then \
		echo "Warning: legacy binary found at /usr/local/bin/$(BINARY)"; \
		echo "Removing to avoid conflicts..."; \
		sudo rm -f /usr/local/bin/$(BINARY); \
	fi
	sudo gtk-update-icon-cache $(DATADIR)/icons/hicolor -q 2>/dev/null || true
	sudo update-desktop-database $(DESKTOPDIR) 2>/dev/null || true
	@echo "FFmpeg Converter GTK installed to $(PREFIX)"

uninstall:
	@if command -v pacman >/dev/null 2>&1 && pacman -Qo $(PREFIX)/bin/$(BINARY) >/dev/null 2>&1; then \
		pacman -Qo $(PREFIX)/bin/$(BINARY); \
		echo "This installation is managed by pacman — uninstall it with:"; \
		echo "    sudo pacman -R ffmpeg-converter-gtk"; \
		exit 1; \
	fi
	sudo rm -f $(PREFIX)/bin/$(BINARY)
	sudo rm -f /usr/local/bin/$(BINARY)
	sudo rm -f $(ICONDIR)/ffmpeg-converter-gtk.svg
	sudo rm -f $(DESKTOPDIR)/ffmpeg-converter-gtk.desktop
	rm -rf $(HOME)/.config/FFmpeg-Converter-GTK
	sudo gtk-update-icon-cache $(DATADIR)/icons/hicolor -q 2>/dev/null || true
	sudo update-desktop-database $(DESKTOPDIR) 2>/dev/null || true
	@echo "FFmpeg Converter GTK has been uninstalled"

clean:
	rm -rf $(BUILDDIR)

rebuild: clean build

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build the application only (default)"
	@echo "  setup            Check dependencies and run meson setup"
	@echo "  build            Compile the application for release-style builds"
	@echo "  test             Build and run the optional Meson test targets"
	@echo "  install          Build and install via meson install"
	@echo "  uninstall        Remove installed files"
	@echo "  clean            Remove the build directory"
	@echo "  rebuild          Clean and rebuild"
	@echo "  help             Show this help message"
