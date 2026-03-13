#!/usr/bin/env sh

set -eu

cd tests/ios

# Pick one available iPhone simulator to avoid hardcoding a model that might not exist.
IOS_SIMULATOR=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {gsub(/^ +| +$/, "", $1); print $1; exit}')

xcodebuild test \
  -project RCTWebRTCTests.xcodeproj \
  -scheme RCTWebRTCTests \
  -destination "platform=iOS Simulator,name=$IOS_SIMULATOR"
