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
# Build a distributable disk image containing NetReport.app alongside a
# shortcut to /Applications, so a user can drag one onto the other.
#
#   bash scripts/build-dmg.sh            # -> dist/NetReport-<version>.dmg
#   VERSION=1.1.0 bash scripts/build-dmg.sh
#
# Uses only tools that ship with macOS (hdiutil); nothing to install first.
#
# NOTE ON GATEKEEPER: this image is ad-hoc signed, not signed with a Developer
# ID and not notarized, because no Developer ID certificate is present on this
# machine. macOS will therefore refuse to open the app by double-click on
# another Mac. The README documents the right-click ▸ Open workaround. To ship
# without that caveat, sign and notarize:
#   codesign --force --deep --options runtime \
#     --sign "Developer ID Application: NAME (TEAMID)" dist/NetReport.app
#   (rebuild the dmg, then)
#   xcrun notarytool submit dist/NetReport-<v>.dmg --apple-id … --team-id … --wait
#   xcrun stapler staple dist/NetReport-<v>.dmg
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

VER="${VERSION:-1.0.0}"
APP="$PROJ/dist/NetReport.app"
STAGE="$PROJ/dist/dmg-stage"
DMG="$PROJ/dist/NetReport-$VER.dmg"
VOLNAME="Net Report $VER"

echo "== 1/4 build the app (release) =="
# SKIP_INSTALL: building an image shouldn't quietly replace the copy in
# ~/Applications as a side effect.
SKIP_INSTALL=1 VERSION="$VER" bash "$PROJ/scripts/build-app.sh"

echo "== 2/4 stage the image contents =="
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/NetReport.app"
ln -s /Applications "$STAGE/Applications"
# A short note travels with the image, since Gatekeeper will complain first.
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Net Report
==========

To install: drag NetReport.app onto the Applications shortcut.

First launch
------------
This app is open source and built by hand, not signed with a paid Apple
Developer ID. macOS blocks such apps on first launch with a message like
"NetReport.app cannot be opened because the developer cannot be verified."

To open it anyway:

  1. Open your Applications folder.
  2. RIGHT-CLICK (or Control-click) NetReport.app and choose Open.
  3. Click Open in the dialog that appears.

You only need to do this once. Afterwards it opens normally.

Source, licence (GPL-3.0) and documentation:
https://github.com/kidvelvet/Net-Report
NOTE

echo "== 3/4 create the disk image =="
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

echo "== 4/4 verify =="
hdiutil verify "$DMG" >/dev/null && echo "  image verifies"
rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | awk '{print $1}')
echo ""
echo "Built: $DMG  ($SIZE)"
echo "SHA-256:"
shasum -a 256 "$DMG" | awk '{print "  " $1}'
