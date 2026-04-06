<div align="center">
  <img src="PingIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Ping Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    <br />
    <a href="https://github.com/farouqaldori/ping-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/farouqaldori/ping-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/farouqaldori/ping-island/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Hook Management** — Install or reinstall hooks for Claude Code, Codex, and compatible clients from settings
- **IDE Terminal Jump** — Optional VS Code-compatible extension lets Ping Island route to the matching project window, then jump to the right terminal tab or session in Cursor, VS Code, CodeBuddy, and Qoder
- **Auto Updates** — Sparkle-powered background update checks with in-app markdown release notes

## Requirements

- macOS 15.6+
- Claude Code CLI

## Install

Download the latest release or build from source:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Release build
```

To create an unsigned distributable package for internal sharing or manual install testing:

```bash
./scripts/package-unsigned.sh
```

## Auto Update Setup

Sparkle runtime configuration is loaded from `Config/App.xcconfig`, which optionally includes a gitignored local override file.

1. Copy `Config/LocalSecrets.example.xcconfig` to `Config/LocalSecrets.xcconfig`
2. Set `SPARKLE_APPCAST_URL`
3. Set `SPARKLE_PUBLIC_ED_KEY`
4. Create version notes in `releases/notes/<version>.md` before running `./scripts/create-release.sh`

Detailed release steps: [docs/sparkle-release.md](docs/sparkle-release.md)

Release notes live in [`releases/notes/`](releases/notes/) with one Markdown file per version.

## Testing

Prototype hosts the repo's fast-running unit and e2e test harnesses for session ingestion, hook mapping, socket transport, and the `IslandBridge` executable path.

```bash
./scripts/test.sh
```

That script runs the full verified regression flow for this repo:

```bash
swift test --package-path Prototype
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGN_IDENTITY=- test
```

The Xcode project also ships app-level unit and UI test targets if you want to run slices manually:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGN_IDENTITY=- test -only-testing:PingIslandUITests
```

On macOS, the UI test runner must pass local code-signing policy before it will leave its initial suspended state. If `PingIslandUITests-Runner` is blocked by `amfid` or `AppleSystemPolicy`, run the UI tests from Xcode with a valid local signing identity configured for the machine.

## CI

Pull requests run GitHub Actions validation automatically through [`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml).

The PR workflow currently runs the stable CI slice for hosted macOS runners:

```bash
swift test --package-path Prototype
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests
```

UI tests stay in the local/full regression path for now because GitHub-hosted runners are more likely to hit code-signing or macOS policy issues during `PingIslandUITests` startup.

## How It Works

Ping Island installs hooks for Claude Code, Codex, and compatible hook clients such as CodeBuddy, Qoder, and QoderWork. Those hooks communicate session state via a Unix socket, and the app listens for events to display them in the notch overlay. `QoderWork` is currently hook-only and is not treated as a VS Code-compatible IDE extension host.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## Analytics

Ping Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Claude Code session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
