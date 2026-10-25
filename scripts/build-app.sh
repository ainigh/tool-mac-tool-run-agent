#!/bin/bash
# Builds build/Peter.app and build/Peter.zip (what a release carries). Needs a Mac with Xcode or
# its Command Line Tools; GitHub Actions runs it on every push, so nobody has to build anything
# by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# UNIVERSAL=0 builds for this Mac's chip only (works with just the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"
NAME=Peter
APP="build/$NAME.app"
# CFBundleVersion must be numbers with dots: VERSION's leading numbers (0.1-abc1234 → 0.1), or 0.
if [[ "$VERSION" =~ ^([0-9]+(\.[0-9]+){0,2}) ]]; then BUNDLE_VERSION="${BUNDLE_VERSION:-${BASH_REMATCH[1]}}"; else BUNDLE_VERSION="${BUNDLE_VERSION:-0}"; fi

# A value as it can go inside the plist's XML.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

command -v swift >/dev/null 2>&1 || {
  echo "error: building needs Swift. Install Apple's command line tools (xcode-select --install), then try again." >&2
  exit 3
}

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release --product "$NAME" ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$NAME" "$APP/Contents/MacOS/$NAME"
cp API.md "$APP/Contents/Resources/API.md"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.peter</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Peter</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml "$VERSION")</string>
  <key>CFBundleVersion</key><string>$(xml "$BUNDLE_VERSION")</string>
  <key>PeterCommit</key><string>$(xml "$COMMIT")</string>
  <key>PeterBranch</key><string>$(xml "$BRANCH")</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>So you can speak to Peter in his window instead of typing.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>What you say to Peter in his window is written down by macOS's speech recognition.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account. Its
# designated requirement is the bundle id alone (not this build's hash), so what macOS has allowed
# the app (the microphone, speech recognition, notifications) carries over to the next version.
BUNDLE_ID=com.ainigh.peter
codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
