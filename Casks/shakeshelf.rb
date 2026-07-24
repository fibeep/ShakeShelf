cask "shakeshelf" do
  version "1.0.1"
  sha256 "3a7a3334ae533df769ff18fa8cebcae5a6a91bf5d6035885eb72b440135aac02"

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
