# Sparkle Release Setup

## Signed GitHub Actions releases

The repo ships `.github/workflows/release-packages.yml` for GitHub-hosted release packaging.

- It runs on `macos-15`.
- It imports your `Developer ID Application` certificate into a temporary keychain.
- It archives and exports the app through `./scripts/package-release.sh`.
- It notarizes the exported app bundle, staples it, then creates signed `.zip` and `.dmg` artifacts.
  - Use the `.dmg` as the primary manual-install artifact.
  - Keep the `.zip` available for update/distribution workflows that still expect it.
- It applies the repo-tracked DMG installer layout and generated branded background during packaging, so local and CI builds share the same installer presentation without depending on a checked-in static poster image.
  - Signed release packaging now fails if Finder styling does not persist into the DMG, so GitHub Actions cannot silently publish a plain installer without the background.
- It creates or updates the matching GitHub Release for a `v*` tag and leaves it in draft by default so you can review it before publishing.
- When Sparkle secrets are configured, it also signs and uploads `appcast.xml` plus the versioned Markdown release notes asset that the app uses for in-app update history.
- It is safe to rerun after a partially failed release upload; the workflow reuses the existing tag release, re-uploads assets with `--clobber`, and then updates the final draft / prerelease state.

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
| `SPARKLE_APPCAST_URL` | Feed URL compiled into the app for Sparkle update checks. Recommended: `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` |
| `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key compiled into the app for Sparkle validation |
| `SPARKLE_PRIVATE_ED_KEY` | Private EdDSA key content used in CI to sign the generated `appcast.xml` and release note assets |

If you configure Sparkle updates in CI, set all three Sparkle secrets together. If you leave them unset, the workflow still produces signed `.dmg` / `.zip` packages, but it will skip appcast generation and upload.

Important: when writing `SPARKLE_APPCAST_URL` into an `.xcconfig`, do not use a raw `https://...` literal. xcconfig treats `//` as the start of a comment, so compose the URL with a slash helper such as `_XC_SLASH = /`.

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
   - Also bump `CURRENT_PROJECT_VERSION` / `CFBundleVersion` for every release. Sparkle relies on the monotonically increasing build version (`sparkle:version`) when deciding whether an update is newer.
3. Push a tag like `v0.0.1`, or open the workflow manually with the same tag name.
4. Publish the GitHub Release manually after reviewing the generated draft, or uncheck the `draft` input when you intentionally want the manual workflow run to publish immediately.

Important: `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` only resolves for the latest published release. If the newest release is still a draft, or the published release was created without the `appcast.xml` asset, Sparkle clients will receive a 404 and update checks will fail.

The workflow will upload the signed `.dmg`, `.zip`, and a zipped Linux bridge payload to the matching GitHub Release draft and add a short note that the artifacts were signed and notarized in CI.
When Sparkle secrets are present, the same draft Release will also include:

- `appcast.xml`
- `PingIsland-<version>.md`

Use the GitHub Release assets as the canonical download surface so the DMG stays a direct `.dmg` file instead of an Actions artifact wrapped in an outer `.zip`.

## Local Sparkle release flow

If you want the full local release path including Sparkle appcast generation and website update:

1. Copy `Config/LocalSecrets.example.xcconfig` to `Config/LocalSecrets.xcconfig`.
2. Fill in:
   - `SPARKLE_APPCAST_URL`
   - `SPARKLE_PUBLIC_ED_KEY`

   Example:

```xcconfig
_XC_SLASH = /
SPARKLE_APPCAST_URL = https:$(_XC_SLASH)/github.com/<owner>/<repo>/releases/latest/download/appcast.xml
SPARKLE_PUBLIC_ED_KEY = YOUR_PUBLIC_ED_KEY
```
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
- `scripts/package-release.sh` now compares the build against the latest earlier published GitHub release and fails if `CFBundleVersion` did not increase.
- `scripts/create-release.sh` packages `releases/notes/<version>.md` as `PingIsland-<version>.md` and uses it as the GitHub Release body when present.
- `scripts/create-release.sh` infers the GitHub repo from `origin` by default; set `PING_ISLAND_GITHUB_REPO=owner/repo` if you need to override it.
- The app prefers Markdown release notes and falls back to Sparkle's explicit release notes links when Markdown is unavailable.
