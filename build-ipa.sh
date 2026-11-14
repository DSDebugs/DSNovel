#!/bin/bash
# DSNovel v7.0 - local macOS IPA build script
# Run on a Mac with Xcode 26+ installed:  bash build-ipa.sh
set -euo pipefail
cd "$(dirname "$0")"

for tool in xcodebuild xcodegen zip; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "[ERROR] Missing $tool. Install Xcode and XcodeGen (brew install xcodegen) first."
    exit 1
  fi
done

SDK_VER=$(xcodebuild -showsdks | grep iphoneos | tail -n 1 | awk '{print $NF}' | sed 's/iphoneos//')
if [ -z "${SDK_VER}" ]; then
  echo "[ERROR] No iOS SDK found. Open Xcode once to finish installing components."
  exit 1
fi
MAJOR="${SDK_VER%%.*}"
echo "[INFO] Detected iOS SDK: ${SDK_VER}"
if [ "${MAJOR}" -lt 26 ]; then
  echo "[WARN] This app uses Liquid Glass (.glassEffect / GlassEffectContainer); iOS 26 SDK or newer is required."
fi

# Adapt deployment target to the installed SDK without touching the committed project.yml
sed "s/27\.0/${SDK_VER}/g" project.yml > project.build.yml
trap 'rm -f project.build.yml' EXIT
xcodegen generate --spec project.build.yml

xcodebuild clean build \
  -project DSNovel.xcodeproj \
  -scheme DSNovel \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

APP_PATH=$(find build -name "DSNovel.app" -type d | head -n 1)
if [ -z "${APP_PATH}" ]; then
  echo "[ERROR] DSNovel.app not found in build output."
  exit 1
fi

rm -rf Payload && mkdir -p Payload
cp -R "${APP_PATH}" Payload/
OUT="DSNovel-iOS27-v7.0-unsigned.ipa"
rm -f "$OUT"
zip -q -r -9 "$OUT" Payload
echo "[OK] Built: $(pwd)/$OUT"
echo "[NOTE] This is an UNSIGNED ipa. To install it on a real iPhone you must re-sign it"
echo "       with your own Apple certificate + provisioning profile (AltStore / Sideloadly / Xcode)."
