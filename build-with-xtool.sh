#!/usr/bin/env bash
# Build an UNSIGNED DSNovel IPA on Windows/WSL (or Linux) with xtool.
# No Apple ID login needed: we never pass --sign and never run `xtool dev`.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APPIMAGE="$(dirname "$ROOT")/tools/xtool-x86_64.AppImage"

echo "[1/5] Swift toolchain (xtool requires Swift 6.4)"
if ! command -v swift > /dev/null 2>&1; then
    echo "ERROR: swift not found. Install Swift 6.4 for Linux: https://swift.org/install/linux"
    exit 1
fi
swift --version

echo "[2/5] Locating xtool"
XTOOL=""
if [ -n "${XTOOL_BIN:-}" ]; then
    XTOOL="$XTOOL_BIN"
elif command -v xtool > /dev/null 2>&1; then
    XTOOL="$(command -v xtool)"
elif [ -f "$APPIMAGE" ]; then
    chmod +x "$APPIMAGE"
    if "$APPIMAGE" --version > /dev/null 2>&1; then
        XTOOL="$APPIMAGE"
    else
        echo "  FUSE not available; extracting AppImage instead..."
        BASE="$(dirname "$APPIMAGE")"
        rm -rf "$BASE/squashfs-root" "$BASE/xtool-extract"
        ( cd "$BASE" && ./xtool-x86_64.AppImage --appimage-extract > /dev/null 2>&1 ) || true
        if [ -d "$BASE/squashfs-root" ]; then
            mv "$BASE/squashfs-root" "$BASE/xtool-extract"
            XTOOL="$BASE/xtool-extract/AppRun"
        fi
    fi
fi
if [ -z "$XTOOL" ]; then
    echo "ERROR: xtool not found. Put it on PATH (XTOOL_BIN), or download:"
    echo "  curl -fL https://github.com/xtool-org/xtool/releases/latest/download/xtool-x86_64.AppImage -o ../tools/xtool-x86_64.AppImage"
    exit 1
fi
"$XTOOL" --version 2>/dev/null || "$XTOOL" --help | head -6

echo "[3/5] Darwin Swift SDK (from Xcode 27 Xcode.xip)"
if ! swift sdk list 2>/dev/null | grep -qi darwin; then
    XIP="${XCODE_XIP:-}"
    if [ -z "$XIP" ] || [ ! -f "$XIP" ]; then
        echo "ERROR: Darwin SDK missing and Xcode.xip not supplied."
        echo "  1. In a BROWSER open https://developer.apple.com/download/all/?q=Xcode"
        echo "     log in with your Apple ID, accept the license, download Xcode 27 Xcode.xip"
        echo "  2. Re-run with its WSL path, e.g.:"
        echo "     XCODE_XIP=/mnt/c/Users/LY-PC/Downloads/Xcode_27.0.xip bash build-with-xtool.sh"
        exit 1
    fi
    "$XTOOL" sdk install "$XIP"
fi
swift sdk list

echo "[4/5] Building UNSIGNED release IPA (no --sign, no auth)"
"$XTOOL" dev build --configuration release --ipa

echo "[5/5] Output"
find "$ROOT" -maxdepth 5 -name "*.ipa" -type f -printf '%p  %s bytes\n' 2>/dev/null || find "$ROOT" -name "*.ipa" -type f
echo "[OK] Done. This IPA is UNSIGNED; re-sign it before installing on a device."
