#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
package_root="$repo_root/Packages/MacEaseCore"
app_path="$repo_root/.build/MacEasePhase0Harness.app"
executable_path="$app_path/Contents/MacOS/GateBLoginHarness"

swift build --package-path "$package_root" -c release --product GateBLoginHarness
bin_path=$(swift build --package-path "$package_root" -c release --show-bin-path)

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path/GateBLoginHarness" "$executable_path"
cp "$repo_root/Support/Phase0Harness-Info.plist" "$app_path/Contents/Info.plist"

codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$repo_root/Support/Phase0Harness.entitlements" \
  "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

print -r -- "$app_path"
