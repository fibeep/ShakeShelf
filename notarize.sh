#!/bin/bash
# Notarizes a signed DMG so it opens on any Mac with no warnings at all.
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership ($99/year)
#   2. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > +)
#   3. Credentials stored in your keychain:
#        xcrun notarytool store-credentials shakeshelf-notary \
#          --apple-id you@example.com \
#          --team-id YOURTEAMID \
#          --password <app-specific-password-from-appleid.apple.com>
#
# Then:
#   ./package.sh "Developer ID Application: Your Name (YOURTEAMID)"
#   ./notarize.sh dist/ShakeShelf-1.0.0.dmg
set -euo pipefail
cd "$(dirname "$0")"

DMG="${1:-}"
PROFILE="${2:-shakeshelf-notary}"

if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "usage: ./notarize.sh <path-to-dmg> [keychain-profile]" >&2
  exit 1
fi

echo "Submitting $DMG for notarization (this usually takes a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling attaches the notarization ticket to the file itself, so it opens
# even on a Mac that is offline and cannot check with Apple.
echo "Stapling ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Done. $DMG will now open on any Mac with no security warnings."
