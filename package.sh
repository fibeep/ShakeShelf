#!/bin/bash
# Packages ShakeShelf.app into a DMG you can send to someone.
#
# Signing:
#   package.sh                        ad-hoc signed (free; recipients must
#                                     approve it in Privacy & Security — see
#                                     SHARING.md)
#   package.sh "Developer ID Application: Your Name (TEAMID)"
#                                     properly signed; add notarization with
#                                     notarize.sh for a warning-free install
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${1:-}"
APP="dist/ShakeShelf.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/ShakeShelf-${VERSION}.dmg"
STAGE="dist/dmg-stage"

./build.sh

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  # --options runtime enables the hardened runtime, which notarization requires.
  codesign --force --deep --options runtime --timestamp -s "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The Applications symlink is what lets the recipient drag-to-install.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "ShakeShelf" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"

echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
if [[ -z "$IDENTITY" ]]; then
  echo
  echo "This build is ad-hoc signed. Recipients will need to approve it once in"
  echo "System Settings > Privacy & Security. See SHARING.md for what to tell them."
fi
