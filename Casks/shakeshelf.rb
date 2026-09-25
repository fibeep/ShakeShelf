cask "shakeshelf" do
  version "1.0.3"
  sha256 "19608e2b881ac24f530e7d1e9638284c946d88b8caab933bdb1cb6caa8df6951"

  url "https://github.com/fibeep/ShakeShelf/releases/download/v#{version}/ShakeShelf-#{version}.dmg",
      verified: "github.com/fibeep/ShakeShelf/"
  name "ShakeShelf"
  desc "Menu-bar shelf for screenshots, text, and colors with built-in dev tools"
  homepage "https://github.com/fibeep/ShakeShelf"

  depends_on macos: ">= :ventura"

  app "ShakeShelf.app"

  # The build is not notarized, so Gatekeeper quarantines it. This removes the
  # quarantine flag on install so it opens without the "Apple cannot check it"
  # prompt. Users who prefer to vet it themselves can drop this line.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ShakeShelf.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/ShakeShelf",
    "~/Library/Preferences/com.salomoncohen.shakeshelf.plist",
  ]
end
