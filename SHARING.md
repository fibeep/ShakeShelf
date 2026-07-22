# Sharing ShakeShelf

`./package.sh` produces `dist/ShakeShelf-1.0.0.dmg` — a universal build that
runs on both Apple Silicon and Intel Macs. Send that file however you like:
AirDrop, email, Dropbox, a GitHub release.

The one wrinkle is Gatekeeper. macOS refuses to open apps from unidentified
developers, and there are two ways around that.

## Option 1 — Send it as-is (free)

Works today with no account and no cost. Your friend has to approve the app
once, because it isn't signed with a certificate Apple recognizes.

Tell them:

1. Open the DMG and drag **ShakeShelf** to **Applications**.
2. Launch it. macOS will say *"ShakeShelf" was blocked to protect your Mac* or
   *cannot be opened because Apple cannot check it for malicious software*.
3. Open **System Settings → Privacy & Security**, scroll to the Security
   section, and click **Open Anyway** next to the ShakeShelf message.
4. Confirm once more. It opens normally from then on.

The tray icon appears in the menu bar — there is no Dock icon and no window
until the shelf is summoned.

Note: on macOS 15 and later, the old right-click → Open trick no longer works;
the Privacy & Security route above is the only way.

This is fine among friends who trust where the app came from. It is *not*
suitable for handing to strangers, who have no reason to bypass a security
warning for an app they can't verify.

## Option 2 — Sign and notarize it ($99/year)

The app opens with no warnings at all, on any Mac. This is what you want if
you're sharing beyond a handful of people or publishing a download link.

One-time setup:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/year).
2. In Xcode → Settings → Accounts → Manage Certificates, add a
   **Developer ID Application** certificate.
3. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com),
   then store your credentials:

   ```sh
   xcrun notarytool store-credentials shakeshelf-notary \
     --apple-id you@example.com \
     --team-id YOURTEAMID \
     --password <app-specific-password>
   ```

Then for each release:

```sh
./package.sh "Developer ID Application: Your Name (YOURTEAMID)"
./notarize.sh dist/ShakeShelf-1.0.0.dmg
```

Notarization takes a few minutes. Stapling attaches the ticket to the DMG so
it opens even on a Mac that's offline.

## Option 3 — Share the source

Technical friends can clone the repo and run `./build.sh` themselves. Locally
built apps aren't quarantined, so Gatekeeper never gets involved. They need
the Xcode command-line tools (`xcode-select --install`).

## Before you send it to anyone

- **Empty your shelf, or check what's on it.** Shelf contents live in
  `~/Library/Application Support/ShakeShelf/Items` and are *not* part of the
  app bundle, so they won't travel with the DMG. Worth knowing anyway if you
  ever zip up that folder.
- **Bump the version** in `Resources/Info.plist` (`CFBundleShortVersionString`)
  so you and your friends can tell builds apart.
- **Change the bundle identifier** if you fork or rename the app; it is
  currently `com.salomoncohen.shakeshelf`.

## What your friends should expect on first run

- macOS may ask for **Desktop folder access** the first time a screenshot is
  auto-added. Approving it is what makes auto-add work.
- **Capture Region** may ask for Screen Recording permission, depending on
  the macOS version.
- Nothing else — the app has no network access, no analytics, and stores
  everything locally.
