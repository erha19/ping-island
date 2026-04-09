# Sparkle Release Setup

## Signed GitHub Actions releases

The repo ships `.github/workflows/release-packages.yml` for GitHub-hosted release packaging.

- It runs on `macos-15`.
- It imports your `Developer ID Application` certificate into a temporary keychain.
- It archives and exports the app through `./scripts/package-release.sh`.
- It notarizes the exported app bundle, staples it, then creates signed `.zip` and `.dmg` artifacts.
- It publishes those assets to the matching GitHub Release for a `v*` tag.
- It is safe to rerun after a partially failed publish; the workflow reuses the existing tag release, re-uploads assets with `--clobber`, and then updates the final draft / prerelease state.

If you have an individual Apple Developer account, that is fine: you do not need a company account for this flow. You do need a `Developer ID Application` certificate. A plain `Apple Development` certificate is not enough for signed, notarized downloads distributed outside the Mac App Store.

### Required repository secrets

Set these in `Settings -> Secrets and variables -> Actions`:

| Secret | Purpose |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of your `Developer ID Application` certificate |
| `P12_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool` |

Optional secrets:

| Secret | Purpose |
| --- | --- |
| `SPARKLE_APPCAST_URL` | Feed URL compiled into the app for Sparkle update checks |
| `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key compiled into the app for Sparkle validation |

### Export the signing certificate

1. Open `Keychain Access`.
2. Export the `Developer ID Application` identity as a `.p12`.
3. Base64-encode it:

```bash
base64 -i developer-id-application.p12 | pbcopy
```

4. Paste the result into the `BUILD_CERTIFICATE_BASE64` secret.

### Trigger the workflow

1. Create release notes at `releases/notes/<version>.md`.
   - Use `releases/notes/README.md` as the authoring template.
2. Make sure the app version matches the release tag.
3. Push a tag like `v0.0.1`, or open the workflow manually with the same tag name.

The workflow will upload the signed `.dmg` and `.zip` to the matching GitHub Release and add a short note that the artifacts were signed and notarized in CI.

## Local Sparkle release flow

If you want the full local release path including Sparkle appcast generation and website update:

1. Copy `Config/LocalSecrets.example.xcconfig` to `Config/LocalSecrets.xcconfig`.
2. Fill in:
   - `SPARKLE_APPCAST_URL`
   - `SPARKLE_PUBLIC_ED_KEY`
3. Generate Sparkle signing keys if you have not already:

```bash
./scripts/generate-keys.sh
```

4. Store notarization credentials locally:

```bash
xcrun notarytool store-credentials "PingIsland" \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

5. Create the notarized DMG, appcast, and release assets:

```bash
./scripts/create-release.sh
```

## Notes

- `Config/LocalSecrets.xcconfig` is intentionally gitignored.
- `scripts/package-release.sh` is the shared build + sign + notarize packaging entrypoint used by both local release tooling and GitHub Actions.
- `scripts/create-release.sh` packages `releases/notes/<version>.md` as `PingIsland-<version>.md` and uses it as the GitHub Release body when present.
- The app prefers Markdown release notes and falls back to Sparkle's explicit release notes links when Markdown is unavailable.
