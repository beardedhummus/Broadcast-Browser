#!/bin/bash
# Builds "Broadcast Browser.app" into ./build
#
#   scripts/build_app.sh            # release build
#   scripts/build_app.sh debug      # debug build
#   SIGN_IDENTITY="My Cert" scripts/build_app.sh   # sign with a stable identity
#
# Optional components picked up automatically:
#   ThirdParty/DeckLinkSDK/include/DeckLinkAPI.h  -> DeckLink SDI/HDMI output
#   ThirdParty/Syphon.framework                   -> bundled for Syphon output
#   ThirdParty/libndi.dylib                       -> bundled NDI runtime

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Broadcast Browser.app"

# The macOS 27 SDK in the Command Line Tools declares SwiftUI's @State as a macro
# whose compiler plugin only ships with full Xcode. Prefer the macOS 26 SDK when
# building without Xcode.
if [[ -z "${SDKROOT:-}" ]]; then
  if xcode-select -p | grep -q CommandLineTools; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
      if [[ -d "$candidate" ]]; then export SDKROOT="$candidate"; break; fi
    done
  fi
fi
SDK_ARGS=()
if [[ -n "${SDKROOT:-}" ]]; then
  SDK_ARGS=(--sdk "$SDKROOT")
  echo "• Using SDK: $SDKROOT"
fi

EXTRA_ARGS=()
DECKLINK_INCLUDE="$ROOT/ThirdParty/DeckLinkSDK/include"
if [[ -f "$DECKLINK_INCLUDE/DeckLinkAPI.h" ]]; then
  echo "• DeckLink SDK found — building with DeckLink support"
  EXTRA_ARGS+=(-Xcc -DBB_HAVE_DECKLINK_SDK=1 -Xcc "-I$DECKLINK_INCLUDE")
else
  echo "• DeckLink SDK not found — DeckLink output will be disabled (see ThirdParty/README.md)"
fi

echo "• Compiling ($CONFIG)…"
swift build -c "$CONFIG" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --show-bin-path)"

echo "• Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/BroadcastBrowser" "$APP/Contents/MacOS/BroadcastBrowser"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICNS="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
  echo "• Rendering app icon…"
  ICONSET="$ROOT/build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ROOT/build"
  swiftc ${SDKROOT:+-sdk "$SDKROOT"} "$ROOT/scripts/make_icon.swift" -o "$ROOT/build/make_icon"
  "$ROOT/build/make_icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "• Rendering OSC reference…"
python3 "$ROOT/scripts/md2html.py" "$ROOT/docs/OSC.md" "$APP/Contents/Resources/OSC.html"

if [[ -d "$ROOT/ThirdParty/Syphon.framework" ]]; then
  echo "• Bundling Syphon.framework"
  cp -R "$ROOT/ThirdParty/Syphon.framework" "$APP/Contents/Frameworks/"
fi
if [[ -f "$ROOT/ThirdParty/libndi.dylib" ]]; then
  echo "• Bundling libndi.dylib"
  cp "$ROOT/ThirdParty/libndi.dylib" "$APP/Contents/Frameworks/"
fi

echo "• Signing…"
IDENTITY="${SIGN_IDENTITY:--}"
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null | \
  while IFS= read -r -d '' item; do codesign --force --sign "$IDENTITY" "$item" >/dev/null; done
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ Built: $APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "  Note: ad-hoc signed. macOS asks for Screen Recording permission again after each rebuild;"
  echo "  set SIGN_IDENTITY to a code-signing certificate to keep the permission between builds."
fi
