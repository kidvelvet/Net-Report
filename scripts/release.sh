#!/usr/bin/env bash
#
# Net Report - a macOS application for running a local amateur radio net.
# Copyright (C) 2026  kidvelvet (W7SKW)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Cut a release in one command: check, test, build the disk image, tag, and
# publish it to GitHub with the image attached.
#
#   bash scripts/release.sh 1.2.0
#   bash scripts/release.sh 1.2.0 --dry-run              # check only, publish nothing
#   bash scripts/release.sh 1.2.0 --notes-file notes.md  # hand-written "What's new"
#
# Everything that can fail is checked *before* anything is published, and the
# tag is only pushed once the image has been built successfully.
set -euo pipefail

CALLER_DIR="$PWD"   # relative paths given on the command line are relative to here
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31merror:\033[0m %s\n\n' "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: bash scripts/release.sh <version> [--dry-run] [--notes-file FILE]

  <version>           semantic version without the leading v, e.g. 1.2.0
  --dry-run           run every check and build the image, but publish nothing
  --notes-file FILE   use FILE as the "What's new" section instead of the commit
                      subjects since the previous tag; the install, first-launch
                      and checksum sections are still generated around it
USAGE
}

VERSION=""
NOTES_FILE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --notes-file) NOTES_FILE="${2:-}"; [ -n "$NOTES_FILE" ] || die "--notes-file needs a path"
                      case "$NOTES_FILE" in /*) ;; *) NOTES_FILE="$CALLER_DIR/$NOTES_FILE" ;; esac
                      shift 2 ;;
        -*)           die "unknown option: $1" ;;
        *)            [ -z "$VERSION" ] || die "version given twice: $VERSION and $1"
                      VERSION="$1"; shift ;;
    esac
done

[ -n "$VERSION" ] || { usage; die "a version is required"; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.0, got: $VERSION"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die "notes file not found: $NOTES_FILE"

TAG="v$VERSION"
DMG="$PROJ/dist/NetReport-$VERSION.dmg"

# ---------------------------------------------------------------------------
# 1. Preconditions — all of them, before anything is created or published.
# ---------------------------------------------------------------------------
say "Checking preconditions for $TAG"

command -v gh >/dev/null || die "the GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
ok "gh authenticated as $(gh api user -q .login 2>/dev/null || echo 'unknown')"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ok "repository $REPO"

[ -z "$(git status --porcelain)" ] || die "working tree has uncommitted changes — commit or stash first"
ok "working tree clean"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || warn "on branch '$BRANCH', not main"

git fetch --quiet --tags origin
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo none)"
[ "$LOCAL" = "$REMOTE" ] || die "HEAD and origin/$BRANCH differ — push or pull first"
ok "in sync with origin/$BRANCH"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"
ok "tag $TAG is free"

gh release view "$TAG" >/dev/null 2>&1 && die "a release for $TAG already exists" || true
ok "no existing release for $TAG"

# ---------------------------------------------------------------------------
# 2. Prove it works before publishing anything.
# ---------------------------------------------------------------------------
say "Building and testing"
swift build 2>&1 | tail -1
TEST_OUT="$(swift test 2>&1 | grep -E 'Test run with' | tail -1 || true)"
[ -n "$TEST_OUT" ] || die "test run produced no result — check: swift test"
case "$TEST_OUT" in
    *passed*) ok "${TEST_OUT#*✔ }" ;;
    *)        die "tests did not pass: $TEST_OUT" ;;
esac

say "Building the disk image"
VERSION="$VERSION" bash "$PROJ/scripts/build-dmg.sh" >/dev/null
[ -f "$DMG" ] || die "expected image not found at $DMG"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ok "$(basename "$DMG") ($(du -h "$DMG" | awk '{print $1}'))"
ok "sha256 $SHA"

# ---------------------------------------------------------------------------
# 3. Release notes. The install, Gatekeeper and checksum sections are mechanical
#    and always generated — the checksum can't be known until the image exists —
#    so a notes file supplies only "What's new" (default: the commit subjects).
# ---------------------------------------------------------------------------
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT

{
    echo "Download \`NetReport-$VERSION.dmg\` below, open it, and drag **NetReport.app** onto the **Applications** shortcut."
    echo
    echo "Requires **macOS 14 (Sonoma) or later** on **Apple Silicon**. Upgrading replaces the app only — your databases, reports, and QRZ login are untouched."
    echo
    echo "## What's new"
    echo
    if [ -n "$NOTES_FILE" ]; then
        cat "$NOTES_FILE"
        echo
    elif [ -n "$PREV_TAG" ]; then
        git log "$PREV_TAG..HEAD" --no-merges --pretty=format:'- %s'
        echo
    else
        echo "- First release."
    fi
    echo
    echo "## ⚠️ First launch"
    echo
    echo "macOS will say *\"NetReport.app cannot be opened because the developer cannot be verified.\"* This is expected: the app is open source and ad-hoc signed rather than signed with a paid Apple Developer ID. Nothing is wrong with your download."
    echo
    echo "1. Install it to **Applications** first (opening straight from the disk image won't work)."
    echo "2. **Right-click** (or Control-click) **NetReport.app** → **Open**."
    echo "3. Click **Open** in the dialog."
    echo
    echo "Once only. Command-line equivalent:"
    echo
    echo '```bash'
    echo "xattr -d com.apple.quarantine /Applications/NetReport.app"
    echo '```'
    echo
    echo "## Verify your download"
    echo
    echo '```bash'
    echo "shasum -a 256 NetReport-$VERSION.dmg"
    echo '```'
    echo
    echo '```'
    echo "$SHA"
    echo '```'
    if [ -n "$PREV_TAG" ]; then
        echo
        echo "**Full changelog:** https://github.com/$REPO/compare/$PREV_TAG...$TAG"
    fi
} > "$NOTES"
ok "release notes ready$([ -n "$NOTES_FILE" ] && echo " (from $NOTES_FILE)" || echo " (generated from ${PREV_TAG:-start}..HEAD)")"

if [ "$DRY_RUN" = 1 ]; then
    say "Dry run — nothing published"
    echo "Would tag:    $TAG at $(git rev-parse --short HEAD)"
    echo "Would upload: $DMG"
    echo "Would create: https://github.com/$REPO/releases/tag/$TAG"
    echo
    echo "--- notes ---"
    cat "$NOTES"
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Publish. The tag goes up only now that the image exists.
# ---------------------------------------------------------------------------
say "Tagging and publishing"
git tag -a "$TAG" -m "Net Report $VERSION"
git push --quiet origin "$TAG"
ok "pushed $TAG"

if ! gh release create "$TAG" \
        "$DMG#NetReport-$VERSION.dmg (Apple Silicon, macOS 14+)" \
        --title "Net Report $VERSION" \
        --notes-file "$NOTES" \
        --verify-tag --latest >/dev/null; then
    die "the release could not be created, but $TAG is already pushed.
       Fix the problem and re-run just the publish step:
         gh release create $TAG \"$DMG\" --title \"Net Report $VERSION\" --verify-tag --latest
       The tag cannot simply be deleted: the repository's \"Immutable release
       tags\" ruleset blocks moving or deleting v* tags. To start over, disable
       that ruleset in Settings > Rules, delete the tag, then re-enable it."
fi
ok "release created"

# ---------------------------------------------------------------------------
# 5. Verify the published artifact really is the one that was built.
# ---------------------------------------------------------------------------
say "Verifying the published download"
TMP="$(mktemp -d)"
if curl -fsSL -o "$TMP/dl.dmg" \
     "https://github.com/$REPO/releases/download/$TAG/NetReport-$VERSION.dmg"; then
    DL_SHA="$(shasum -a 256 "$TMP/dl.dmg" | awk '{print $1}')"
    if [ "$DL_SHA" = "$SHA" ]; then
        ok "downloaded image matches the published checksum"
    else
        warn "downloaded checksum $DL_SHA does not match $SHA — investigate before announcing"
    fi
else
    warn "could not download the asset back (it may still be propagating)"
fi
rm -rf "$TMP"

say "Released $TAG"
echo "https://github.com/$REPO/releases/tag/$TAG"
