cask "layby" do
  version :latest
  sha256 :no_check

  url "https://github.com/gonnabeafreeman/Layby/releases/latest/download/Layby.zip"
  name "Layby"
  desc "A handy place for files you’ll need in a moment."
  homepage "https://github.com/gonnabeafreeman/Layby"

  app "Layby.app"

  zap trash: [
    "~/Library/Containers/com.gonnabeafreeman.Layby"
  ]
end