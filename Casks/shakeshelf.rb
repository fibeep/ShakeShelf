cask "shakeshelf" do
  version "1.0.0"
  sha256 "304466e75e2ad3cf18fada10927c500bc219c9818973a921281fcc59aba8328b"

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
