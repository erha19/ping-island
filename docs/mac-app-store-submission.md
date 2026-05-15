# Mac App Store Submission Notes

Ping Island's normal `PingIsland` target remains packaged for direct Developer
ID distribution through GitHub Releases, notarization, and Sparkle updates. The
Mac App Store build uses the separate `PingIslandAppStore` target and shared
scheme so App Store signing, sandboxing, and updater behavior do not change the
current direct-download lane.

## Current App Identity

- App Store name: Ping Island
- Bundle display name: Ping Island
- Bundle ID: `com.wudanwu.PingIsland`
- Version: `0.14.0`
- Build: `42`
- Xcode: 26.4
- Primary category: Developer Tools
- Suggested App Store Connect SKU: `ping-island-macos`

## App Store Build Lane

- Target: `PingIslandAppStore`
- Scheme: `PingIslandAppStore`
- Info plist: `PingIsland/Info-AppStore.plist`
- Entitlements: `PingIsland/Resources/PingIsland-AppStore.entitlements`
- Build wrapper: `./scripts/build-app-store.sh`

The App Store target:

- enables App Sandbox,
- removes the Sparkle package dependency from the App Store target,
- compiles the update manager with `APP_STORE`, which turns the independent
  updater into a no-op managed-by-App-Store path,
- keeps the existing `PingIsland` target unchanged for Developer ID releases.

## Submission Status

Validated on 2026-05-05:

- Xcode automatic distribution used a cloud-managed Apple Distribution
  certificate and generated a Mac Team Store provisioning profile for
  `com.wudanwu.PingIsland`.
- Build `0.9.3` (`33`) uploaded successfully to App Store Connect and entered
  package processing.
- `PingIslandBridge` is signed with the same sandbox entitlements as the app
  bundle so App Store Connect accepts the embedded executable.

Known warning: symbol upload currently reports a missing `PingIslandBridge` dSYM.
This does not block the package upload, but crash symbolication for the bridge
binary will be incomplete until the archive includes that dSYM.

## Local Readiness Check

Validated on 2026-05-05:

```sh
xcodebuild -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: build succeeded.

## Remaining Items Before Review

1. Audit sandbox-incompatible features.

   Core Ping Island workflows read and write tool configs under locations such as
   `~/.claude`, `~/.codex`, `~/.gemini`, `~/.qwen`, `~/.qoder`, `~/.hermes`, and
   remote SSH targets. A sandboxed build needs a deliberate access model, likely
   user-selected directories, security-scoped bookmarks, and feature gating for
   unsupported automatic installs.

2. Complete App Store Connect review metadata.

   The App Store Connect app record must include screenshots, age rating,
   review contact info, and privacy nutrition label answers before the build can
   be submitted for review.

## Upload Command Shape

Unsigned local archive validation:

```sh
PING_ISLAND_SKIP_APP_STORE_SIGNING=1 ./scripts/build-app-store.sh
```

Signed export for App Store Connect:

```sh
PING_ISLAND_TEAM_ID=K46RM9974S ./scripts/build-app-store.sh
```

Signed upload to App Store Connect:

```sh
PING_ISLAND_TEAM_ID=K46RM9974S \
PING_ISLAND_APP_STORE_UPLOAD=1 \
./scripts/build-app-store.sh
```

The script uses an export options plist with:

```xml
<key>method</key>
<string>app-store-connect</string>
<key>destination</key>
<string>upload</string>
```

`xcodebuild -allowProvisioningUpdates` can use a signed-in Xcode account or an
App Store Connect API key via `-authenticationKeyPath`, `-authenticationKeyID`,
and `-authenticationKeyIssuerID`.

## Metadata Draft

- Title: Ping Island
- Subtitle: AI coding session monitor
- Promotional text: Monitor Claude Code, Codex, Gemini CLI, Qwen Code, Hermes, and compatible hook-driven agent sessions from a native macOS menu bar utility.
- Description: Ping Island brings AI coding session status, approval prompts, follow-up questions, remote SSH activity, and completion notifications into a compact macOS menu bar surface. It supports Claude Code, Codex, Gemini CLI, Qwen Code, Hermes Agent, and compatible hook-driven clients, with mascot-rich status views, terminal jump-back, and docked or detached modes.
- Keywords: Claude Code, Codex, Gemini CLI, AI coding, menu bar, developer tools
- Support URL: https://github.com/erha19/ping-island/issues
- Privacy policy URL: https://github.com/erha19/ping-island/blob/main/docs/privacy-policy.md
