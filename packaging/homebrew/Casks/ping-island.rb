cask "ping-island" do
  version "0.9.2"
  sha256 "efec4785e068bacc2540f2ec215685fde66a5aa170c0912cb8ca4ce09a38d4e7"

  url "https://github.com/erha19/ping-island/releases/download/v#{version}/PingIsland-#{version}.dmg",
      verified: "github.com/erha19/ping-island/"
  name "Ping Island"
  desc "Menu bar status for coding agent sessions"
  homepage "https://erha19.github.io/ping-island/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Ping Island.app"

  zap trash: [
    "~/Library/Application Support/PingIsland",
    "~/Library/Caches/com.wudanwu.PingIsland",
    "~/Library/HTTPStorages/com.wudanwu.PingIsland",
    "~/Library/Preferences/com.wudanwu.PingIsland.plist",
    "~/Library/Saved Application State/com.wudanwu.PingIsland.savedState",
  ]
end
