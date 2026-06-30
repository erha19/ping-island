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
- Version: `0.24.2`
- Build: `62`
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
- uses the `group.com.wudanwu.PingIsland` App Group for the local hook bridge
  socket and bridge runtime config,
- enables app-scoped security bookmarks so the user-selected hooks directory
  authorization can survive app relaunches,
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
- App Store hook installs now persist a security-scoped bookmark for the
  user-selected home directory, and the generated launcher exports
  `ISLAND_SOCKET_PATH` / `PING_ISLAND_BRIDGE_CONFIG` into the App Group runtime
  directory before launching `PingIslandBridge`.

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

1. Audit remaining sandbox-incompatible features.

   Local hook installs use user-selected home-directory authorization plus a
   persisted security-scoped bookmark. The local bridge socket and runtime config
   live under the App Group container. Remote SSH flows and any future automatic
   installs outside the selected home directory still need deliberate review and
   feature gating before App Store submission.

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

Before running a signed export, ensure the Apple Developer App ID for
`com.wudanwu.PingIsland` has the `group.com.wudanwu.PingIsland` App Group
enabled; otherwise provisioning will fail even though local unsigned validation
can build.

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
For local command-line uploads, the script also passes
`-allowProvisioningDeviceRegistration` by default so Xcode can register the
current Mac when it needs a development profile for the archive phase; set
`PING_ISLAND_ALLOW_PROVISIONING_DEVICE_REGISTRATION=0` to disable that behavior.

## Metadata Draft

- Title: Ping Island
- Subtitle: AI coding session monitor
- Promotional text: Monitor Claude Code, Codex, Gemini CLI, Qwen Code, Hermes, and compatible hook-driven agent sessions from a native macOS menu bar utility.
- Description: Ping Island brings AI coding session status, approval prompts, follow-up questions, remote SSH activity, and completion notifications into a compact macOS menu bar surface. It supports Claude Code, Codex, Gemini CLI, Qwen Code, Hermes Agent, and compatible hook-driven clients, with mascot-rich status views, terminal jump-back, and docked or detached modes.
- Keywords: Claude Code, Codex, Gemini CLI, AI coding, menu bar, developer tools
- Support URL: https://github.com/erha19/ping-island/issues
- Privacy policy URL: https://github.com/erha19/ping-island/blob/main/docs/privacy-policy.md
