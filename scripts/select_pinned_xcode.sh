#!/usr/bin/env bash
# Locate and select the exact pinned Xcode toolchain (Xcode 26.0.1 / 17A400)
# required by toolchain.json. A missing exact pin is an ENVIRONMENT ACCEPTANCE
# BLOCKER — never silently substitute another Xcode version.
#
# On success: prints the DEVELOPER_DIR path for the matching Xcode to stdout
# and exits 0. On failure: prints an enumeration of candidates to stderr and
# exits 1. Shared by ci.yml's ios-build job pattern and release.yml.
set -euo pipefail

REQUIRED_VERSION="Xcode 26.0.1"
REQUIRED_BUILD="17A400"
found=""

for app in /Applications/Xcode_26.0.1.app /Applications/Xcode_26.0.1_*.app /Applications/Xcode_26.0.app /Applications/Xcode.app; do
  [ -d "$app" ] || continue
  dev="$app/Contents/Developer"
  ver=$(DEVELOPER_DIR="$dev" xcodebuild -version 2>/dev/null | tr -d '\r') || continue
  vline=$(echo "$ver" | head -1)
  bline=$(echo "$ver" | grep -i "build version" | awk '{print $3}')
  if [ "$vline" = "$REQUIRED_VERSION" ] && [ "$bline" = "$REQUIRED_BUILD" ]; then
    found="$dev"
    echo "Exact pin found: $app ($vline, build $bline)" >&2
    break
  fi
done

if [ -z "$found" ]; then
  echo "::error::ACCEPTANCE BLOCKER: required toolchain $REQUIRED_VERSION ($REQUIRED_BUILD) not present on this runner. Enumerated candidates:" >&2
  for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    echo "$app -> $(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>/dev/null | tr -d '\r' | head -1)" >&2
  done
  exit 1
fi

echo "$found"
