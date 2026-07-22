#!/bin/bash
# Builds ShakeShelf.app into dist/
#
# Produces a universal (Apple Silicon + Intel) binary so the same bundle runs
# on any Mac you hand it to. Pass --fast to build only for this machine while
# iterating.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--fast" ]]; then
  swift build -c release
  BINARY=".build/release/ShakeShelf"
else
  swift build -c release --arch arm64 --arch x86_64
  BINARY=".build/apple/Products/Release/ShakeShelf"
fi

# Stop a running instance so `open` launches the fresh build instead of
# re-activating the old process.
pkill -x ShakeShelf 2>/dev/null || true

APP="dist/ShakeShelf.app"
# Update the bundle in place (no rm -rf): launch-at-login registrations
# point at this path, so the directory should survive rebuilds.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BINARY" "$APP/Contents/MacOS/ShakeShelf"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Note: every rebuild changes it, and macOS keys privacy
# grants to the signature — expect to re-approve Desktop access after rebuilds.
# To share the app with other people, see package.sh and SHARING.md.
codesign --force -s - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ShakeShelf"))"
