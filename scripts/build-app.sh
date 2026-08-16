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

#
# Assemble a self-contained NetReport.app (Apple Silicon) from the release build.
# NetReport links only system frameworks (SwiftUI, CoreGraphics, CoreText,
# Foundation), so there is nothing to embed — we just wrap the binary in a
# bundle and ad-hoc sign it.
#
# Re-sign for distribution with your Developer ID, e.g.:
#   codesign --force --options runtime \
#     --sign "Developer ID Application: Your Name (TEAMID)" NetReport.app
#   xcrun notarytool submit NetReport.zip --apple-id … --team-id … --wait
#   xcrun stapler staple NetReport.app
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"
APP="$PROJ/dist/NetReport.app"
ID="${BUNDLE_ID:-com.w7skw.netreport}"
VER="0.1.0"

echo "== 1/4 release build =="
swift build -c release --product NetReport
BIN="$(swift build -c release --product NetReport --show-bin-path)/NetReport"

echo "== 2/4 assemble bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetReport"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Net Report</string>
  <key>CFBundleDisplayName</key><string>Net Report</string>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleVersion</key><string>${VER}</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleExecutable</key><string>NetReport</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

echo "== 3/4 ad-hoc sign =="
codesign --force --sign - "$APP"

# Install (replace) into the user Applications folder on every build.
# ~/Applications is used instead of /Applications because it needs no admin
# password; override with INSTALL_DIR=/Applications (requires write access there).
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
echo "== 4/4 install to $INSTALL_DIR =="
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/NetReport.app"
ditto "$APP" "$INSTALL_DIR/NetReport.app"

echo ""
echo "Built:     $APP"
echo "Installed: $INSTALL_DIR/NetReport.app"
echo "Run:       open \"$INSTALL_DIR/NetReport.app\""
