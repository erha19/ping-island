# Sparkle Release Setup

## One-time setup

1. Copy `Config/LocalSecrets.example.xcconfig` to `Config/LocalSecrets.xcconfig`.
2. Fill in:
   - `SPARKLE_APPCAST_URL`
   - `SPARKLE_PUBLIC_ED_KEY`
3. Generate signing keys if you have not already:

```bash
./scripts/generate-keys.sh
```

## Per-release flow

1. Create release notes at `releases/notes/<version>.md`.
   - Use `releases/notes/README.md` as the authoring template.
2. Build the app:

```bash
./scripts/build.sh
```

3. Create the notarized DMG, appcast, and release assets:

```bash
./scripts/create-release.sh
```

## Notes

- `Config/LocalSecrets.xcconfig` is intentionally gitignored.
- `scripts/create-release.sh` will package `releases/notes/<version>.md` as `PingIsland-<version>.md`.
- The app prefers Markdown release notes and falls back to Sparkle's explicit release notes links when Markdown is unavailable.
