#!/bin/zsh
# Build, install to ~/Applications, drop the build copy from LaunchServices (avoids a duplicate extension in Safari).
set -e
cd "$(dirname "$0")"
# Signing team: $DEVELOPMENT_TEAM, or the first line of an untracked ./.team file.
TEAM="${DEVELOPMENT_TEAM:-$(cat .team 2>/dev/null | head -1)}"
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM=<your Apple team id> (or put it in ./.team)"; exit 1; }
# Bundle id base: $ANYPIP_BUNDLE_ID, or the first line of an untracked ./.bundle file (default: placeholder).
BUNDLE="${ANYPIP_BUNDLE_ID:-$(cat .bundle 2>/dev/null | head -1)}"
BUNDLE="${BUNDLE:-com.example.anypip}"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -x AnyPiP || true
nice xcodebuild -project AnyPiP/AnyPiP.xcodeproj -scheme AnyPiP -configuration Debug -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" ANYPIP_BUNDLE_ID="$BUNDLE" build | grep -E "error:|BUILD"
rm -rf ~/Applications/AnyPiP.app
cp -R build/Build/Products/Debug/AnyPiP.app ~/Applications/
$LS -u build/Build/Products/Debug/AnyPiP.app; rm -rf build
open ~/Applications/AnyPiP.app
