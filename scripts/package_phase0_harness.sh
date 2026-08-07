#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
package_root="$repo_root/Packages/MacEaseCore"
arch=arm64
signing_identity=-
short_version=0.1
build_number=1

while (( $# > 0 )); do
  case "$1" in
    --arch)
      arch="$2"
      shift 2
      ;;
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
      print -r -- "usage: $0 [--arch arm64|x86_64] [--identity IDENTITY] [--version VERSION] [--build BUILD]"
      exit 0
      ;;
    *)
      print -u2 -r -- "unknown option: $1"
      exit 2
      ;;
  esac
done

if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
  print -u2 -r -- "unsupported architecture: $arch"
  exit 2
fi

if [[ "$arch" == arm64 ]]; then
  app_path="$repo_root/.build/MacEasePhase0Harness.app"
else
  app_path="$repo_root/.build/MacEasePhase0Harness-$arch.app"
fi
executable_path="$app_path/Contents/MacOS/GateBLoginHarness"

swift build --package-path "$package_root" -c release --arch "$arch" --product GateBLoginHarness
bin_path=$(swift build --package-path "$package_root" -c release --arch "$arch" --show-bin-path)

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path/GateBLoginHarness" "$executable_path"
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
if [[ "$signing_identity" != - ]]; then
  codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --verbose=4 "$app_path" 2>&1 | sed -n '1,24p'
file "$executable_path"
lipo -info "$executable_path"

print -r -- "$app_path"
