#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
package_root="$repo_root/Packages/MacEaseCore"
signing_identity=-
short_version=0.1
build_number=1

while (( $# > 0 )); do
  case "$1" in
    --identity)
      signing_identity="$2"
      shift 2
      ;;
    --version)
      short_version="$2"
      shift 2
      ;;
    --build)
      build_number="$2"
      shift 2
      ;;
    -h|--help)
      print -r -- "usage: $0 [--identity IDENTITY] [--version VERSION] [--build BUILD]"
      exit 0
      ;;
    *)
      print -u2 -r -- "unknown option: $1"
      exit 2
      ;;
  esac
done

app_path="$repo_root/.build/MacEasePhase0Harness.app"
login_executable_path="$app_path/Contents/MacOS/GateBLoginHarness"
playback_executable_path="$app_path/Contents/MacOS/GateCPlaybackProbe"

swift build --package-path "$package_root" -c release --arch arm64 --product GateBLoginHarness
swift build --package-path "$package_root" -c release --arch arm64 --product GateCPlaybackProbe
bin_path=$(swift build --package-path "$package_root" -c release --arch arm64 --show-bin-path)

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path/GateBLoginHarness" "$login_executable_path"
cp "$bin_path/GateCPlaybackProbe" "$playback_executable_path"
cp "$repo_root/Support/Phase0Harness-Info.plist" "$app_path/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$short_version" "$app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"

codesign_args=(
  --force
  --sign "$signing_identity"
  --options runtime
  --entitlements "$repo_root/Support/Phase0Harness.entitlements"
)
playback_codesign_args=(
  --force
  --sign "$signing_identity"
  --options runtime
)
if [[ "$signing_identity" != - ]]; then
  codesign_args+=(--timestamp)
  playback_codesign_args+=(--timestamp)
fi
codesign "${playback_codesign_args[@]}" "$playback_executable_path"
codesign --verify --strict --verbose=2 "$playback_executable_path"
codesign "${codesign_args[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --verbose=4 "$app_path" 2>&1 | sed -n '1,24p'
for executable_path in "$login_executable_path" "$playback_executable_path"; do
  file "$executable_path"
  lipo -info "$executable_path"
  [[ $(lipo -archs "$executable_path") == arm64 ]] || {
    print -u2 -r -- "packaged executable is not arm64-only: $executable_path"
    exit 1
  }
done

print -r -- "$app_path"
