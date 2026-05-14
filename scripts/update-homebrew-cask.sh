#!/bin/bash
# Update the Ping Island Homebrew Cask in an external tap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="PingIsland"
DEFAULT_TAP_REPO="erha19/homebrew-tap"
DEFAULT_TAP_BRANCH="main"
DEFAULT_CASK_NAME="ping-island"
DEFAULT_CASK_PATH="Casks/ping-island.rb"

VERSION=""
DMG_PATH=""
TAP_DIR="${PING_ISLAND_HOMEBREW_TAP_DIR:-}"
TAP_REPO="${PING_ISLAND_HOMEBREW_TAP_REPO:-$DEFAULT_TAP_REPO}"
TAP_BRANCH="${PING_ISLAND_HOMEBREW_TAP_BRANCH:-$DEFAULT_TAP_BRANCH}"
CASK_NAME="${PING_ISLAND_HOMEBREW_CASK_NAME:-$DEFAULT_CASK_NAME}"
CASK_PATH="${PING_ISLAND_HOMEBREW_CASK_PATH:-$DEFAULT_CASK_PATH}"
PUSH=0
COMMIT=1
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: scripts/update-homebrew-cask.sh --version <version> --dmg <path> [options]

Options:
  --tap-dir <path>        Existing homebrew tap checkout to update.
  --tap-repo <owner/repo> GitHub tap repo to clone when --tap-dir is omitted.
                          Defaults to erha19/homebrew-tap.
  --tap-branch <branch>   Branch to push. Defaults to main.
  --cask-path <path>      Path inside the tap. Defaults to Casks/ping-island.rb.
  --no-commit            Write the cask file without committing.
  --push                 Push the commit to the tap remote.
  --dry-run              Print the generated cask without writing.
  -h, --help             Show this help.

Environment:
  PING_ISLAND_HOMEBREW_TAP_TOKEN  GitHub token used when cloning/pushing the tap.
  PING_ISLAND_HOMEBREW_TAP_REPO   Override default tap repo.
  PING_ISLAND_HOMEBREW_TAP_DIR    Override tap checkout path.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --dmg)
            DMG_PATH="${2:-}"
            shift 2
            ;;
        --tap-dir)
            TAP_DIR="${2:-}"
            shift 2
            ;;
        --tap-repo)
            TAP_REPO="${2:-}"
            shift 2
            ;;
        --tap-branch)
            TAP_BRANCH="${2:-}"
            shift 2
            ;;
        --cask-path)
            CASK_PATH="${2:-}"
            shift 2
            ;;
        --no-commit)
            COMMIT=0
            shift
            ;;
        --push)
            PUSH=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "ERROR: --version is required" >&2
    exit 1
fi

if [ -z "$DMG_PATH" ]; then
    echo "ERROR: --dmg is required" >&2
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG not found at $DMG_PATH" >&2
    exit 1
fi

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

render_cask() {
    cat <<EOF
cask "$CASK_NAME" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/erha19/ping-island/releases/download/v#{version}/$APP_NAME-#{version}.dmg",
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
EOF
}

if [ "$DRY_RUN" = "1" ]; then
    render_cask
    exit 0
fi

cleanup_dir=""
cleanup() {
    if [ -n "$cleanup_dir" ]; then
        rm -rf "$cleanup_dir"
    fi
}
trap cleanup EXIT

if [ -z "$TAP_DIR" ]; then
    cleanup_dir="$(mktemp -d "${TMPDIR:-/tmp}/ping-island-homebrew-tap.XXXXXX")"
    TAP_DIR="$cleanup_dir/homebrew-tap"

    if [ -n "${PING_ISLAND_HOMEBREW_TAP_TOKEN:-}" ]; then
        git clone "https://x-access-token:${PING_ISLAND_HOMEBREW_TAP_TOKEN}@github.com/${TAP_REPO}.git" "$TAP_DIR"
    else
        gh repo clone "$TAP_REPO" "$TAP_DIR"
    fi
fi

if [ ! -d "$TAP_DIR/.git" ]; then
    echo "ERROR: Tap directory is not a git checkout: $TAP_DIR" >&2
    exit 1
fi

if ! git -C "$TAP_DIR" diff --quiet || ! git -C "$TAP_DIR" diff --cached --quiet; then
    echo "ERROR: Tap checkout has uncommitted changes: $TAP_DIR" >&2
    exit 1
fi

mkdir -p "$(dirname "$TAP_DIR/$CASK_PATH")"
render_cask > "$TAP_DIR/$CASK_PATH"
ruby -c "$TAP_DIR/$CASK_PATH" >/dev/null

echo "Updated $TAP_DIR/$CASK_PATH"
echo "Version: $VERSION"
echo "SHA256: $SHA256"

if [ "$COMMIT" = "1" ]; then
    if [ -z "$(git -C "$TAP_DIR" status --porcelain -- "$CASK_PATH")" ]; then
        echo "Cask is already current."
    else
        git -C "$TAP_DIR" add "$CASK_PATH"

        if ! git -C "$TAP_DIR" config user.name >/dev/null; then
            git -C "$TAP_DIR" config user.name "github-actions[bot]"
        fi

        if ! git -C "$TAP_DIR" config user.email >/dev/null; then
            git -C "$TAP_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
        fi

        git -C "$TAP_DIR" commit -m "Publish Ping Island $VERSION to Homebrew Cask

Update the cask to point at the notarized GitHub Release DMG.

Constraint: Homebrew installs from the same release asset used by manual downloads
Confidence: high
Scope-risk: narrow
Directive: Keep the cask URL aligned with scripts/package-release.sh asset names
Tested: ruby -c $CASK_PATH
Not-tested: End-to-end brew install on a fresh macOS machine"
    fi
fi

if [ "$PUSH" = "1" ]; then
    git -C "$TAP_DIR" push origin "HEAD:$TAP_BRANCH"
fi
