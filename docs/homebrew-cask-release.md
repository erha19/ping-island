# Homebrew Cask Release Notes

NotchCode (灵动码) builds on the upstream [Ping Island](https://github.com/erha19/ping-island)
project. The upstream project is still published through the official Homebrew Cask
repository as `ping-island`:

```bash
brew install --cask ping-island
```

For this derivative distribution, publish a separate cask name such as `notchcode`
only after you own the download URL and artifact naming (`NotchCode-<version>.dmg`).

Machines that still have the legacy `erha19/tap` tap may resolve that tap before
the official cask. Remove the old tap once before checking the official source:

```bash
brew untap erha19/tap
brew install --cask ping-island
```

The cask installs from the same notarized DMG that the GitHub Release and
Sparkle release flow publish.

## CI Release Flow

The release workflow is intentionally limited to assets owned by this
repository:

1. Build and notarize the macOS app (`NotchCode.app`).
2. Publish the signed DMG and ZIP to the matching GitHub Release.
3. Publish Sparkle appcast assets when Sparkle signing secrets are configured.
4. Publish the Linux `PingIslandBridge` assets for remote SSH bootstrap.

The workflow no longer pushes to an external `homebrew-tap` repository. That
keeps release CI focused on first-party build artifacts and avoids a second
GitHub token with write access to a tap.

## Release Verification

After a stable GitHub Release is published, verify that Homebrew can see the
official cask:

```bash
brew update
brew info --cask ping-island
```

If `brew info` reports `From: https://github.com/erha19/homebrew-tap.git`, the
local machine is still resolving the legacy tap. Run `brew untap erha19/tap` and
check again.

For a full install check on a clean macOS machine:

```bash
brew install --cask ping-island
```

If Homebrew has not picked up the latest version yet, update the official cask
through Homebrew's normal cask contribution flow instead of changing this
repository's release CI.
