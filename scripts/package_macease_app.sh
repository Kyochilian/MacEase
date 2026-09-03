#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
package_root="$repo_root/Packages/MacEaseCore"
info_plist="$repo_root/Support/MacEase-Info.plist"
entitlements="$repo_root/Support/MacEase.entitlements"
user_home_directory=${HOME:-}
if [[ -n "$user_home_directory" ]]; then
  user_home_directory=${user_home_directory:A}
fi
signing_identity=-
short_version=0.1
build_number=1
output_directory="$repo_root/.build"
feed_url=
public_key=
replace_existing=false
check_only=false

usage() {
  print -r -- \
    "usage: $0 [--identity IDENTITY] [--version VERSION] [--build BUILD]" \
    "[--output-directory DIRECTORY] [--feed-url HTTPS_URL]" \
    "[--public-key BASE64] [--replace] [--check]"
}

die() {
  print -u2 -r -- "error: $1"
  exit 1
}

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
  [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

validate_https_url() {
  local value=$1
  local authority=${value#https://}
  authority=${authority%%/*}
  [[ "$value" == https://* ]] || die "the Sparkle appcast URL must use HTTPS"
  [[ -n "$authority" && "$authority" != *"@"* ]] \
    || die "the Sparkle appcast URL must have a host and no embedded credentials"
  [[ "$value" != *[[:space:]]* && "$value" != *'?'* && "$value" != *'#'* ]] \
    || die "the Sparkle appcast URL must be a stable public URL"
}

validate_public_key() {
  local decoded
  decoded=$(mktemp "${TMPDIR:-/tmp}/macease-public-key.XXXXXX") \
    || die "could not create a temporary validation file"
  if ! print -rn -- "$1" | base64 --decode > "$decoded" 2>/dev/null; then
    rm -f -- "$decoded"
    die "the Sparkle public key is not valid base64"
  fi
  local byte_count
  byte_count=$(wc -c < "$decoded" | tr -d ' ')
  rm -f -- "$decoded"
  [[ "$byte_count" == 32 ]] || die "the Sparkle public key must decode to 32 bytes"
}

while (( $# > 0 )); do
  case "$1" in
    --identity)
      require_value "$@"
      signing_identity="$2"
      shift 2
      ;;
    --version)
      require_value "$@"
      short_version="$2"
      shift 2
      ;;
    --build)
      require_value "$@"
      build_number="$2"
      shift 2
      ;;
    --output-directory)
      require_value "$@"
      output_directory="$2"
      shift 2
      ;;
    --feed-url)
      require_value "$@"
      feed_url="$2"
      shift 2
      ;;
    --public-key)
      require_value "$@"
      public_key="$2"
      shift 2
      ;;
    --replace)
      replace_existing=true
      shift
      ;;
    --check)
      check_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -r -- "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

version_pattern='^[0-9]+([.][0-9]+){1,3}([-.][0-9A-Za-z]+)*$'
build_pattern='^[1-9][0-9]*$'
[[ "$short_version" =~ $version_pattern ]] || die "invalid short version"
[[ "$build_number" =~ $build_pattern ]] || die "build number must be a positive integer"
[[ -f "$info_plist" && -f "$entitlements" ]] || die "support configuration is missing"
plutil -lint "$info_plist" "$entitlements" >/dev/null
[[ $(plutil -extract SUEnableInstallerLauncherService raw "$info_plist") == true ]] \
  || die "Sparkle's sandboxed installer service is not enabled"
[[ $(plutil -extract 'com\.apple\.security\.app-sandbox' raw "$entitlements") == true ]] \
  || die "the release entitlements do not enable App Sandbox"
resolved_package="$package_root/Package.resolved"
[[ -f "$resolved_package" ]] || die "Package.resolved is missing"
[[ $(plutil -extract pins.0.identity raw "$resolved_package") == sparkle \
  && $(plutil -extract pins.0.location raw "$resolved_package") \
    == "https://github.com/sparkle-project/Sparkle" \
  && $(plutil -extract pins.0.state.version raw "$resolved_package") == 2.9.6 ]] \
  || die "the pinned Sparkle 2.9.6 dependency is missing"

if [[ -n "$feed_url" || -n "$public_key" ]]; then
  [[ -n "$feed_url" && -n "$public_key" ]] \
    || die "--feed-url and --public-key must be supplied together"
  validate_https_url "$feed_url"
  validate_public_key "$public_key"
fi
if [[ "$signing_identity" != - ]]; then
  [[ -n "$feed_url" && -n "$public_key" ]] \
    || die "a certificate-signed package requires the Sparkle feed URL and public key"
else
  [[ -z "$feed_url" && -z "$public_key" ]] \
    || die "an ad-hoc development package must not contain live update configuration"
fi

output_directory=${output_directory:A}
[[ "$output_directory" != / && "$output_directory" != "$repo_root" \
  && ( -z "$user_home_directory" || "$output_directory" != "$user_home_directory" ) ]] \
  || die "refusing to use a broad output directory"

if $check_only; then
  print -r -- "MacEase package configuration is valid; no build or signing was performed."
  exit 0
fi

[[ "$signing_identity" == - ]] \
  || die "package only creates ad-hoc staging; use release sign for Developer ID signing"
[[ -z "$feed_url" && -z "$public_key" ]] \
  || die "an ad-hoc package must not contain live update configuration"

mkdir -p -- "$output_directory"
output_directory=${output_directory:A}
[[ -d "$output_directory" && -w "$output_directory" ]] \
  || die "the output directory is not writable"

app_path="$output_directory/MacEase.app"
if [[ -e "$app_path" || -L "$app_path" ]]; then
  $replace_existing || die "$app_path already exists; pass --replace to replace that exact app"
  [[ "${app_path:A:h}" == "$output_directory" && "$app_path:t" == MacEase.app ]] \
    || die "refusing to replace an unresolved output path"
fi

swift build --package-path "$package_root" -c release --arch arm64 --product MacEase
bin_path=$(swift build \
  --package-path "$package_root" -c release --arch arm64 --show-bin-path)
[[ -x "$bin_path/MacEase" ]] || die "the Release executable is missing"
[[ -d "$bin_path/Sparkle.framework" ]] || die "the Sparkle framework is missing"

staging_directory=$(mktemp -d "$output_directory/.macease-package.XXXXXX") \
  || die "could not create the package staging directory"
staging_directory=${staging_directory:A}
[[ -d "$staging_directory" && "$staging_directory:h" == "$output_directory" \
  && "$staging_directory:t" == .macease-package.* ]] \
  || die "the package staging directory did not resolve safely"
trap 'rm -rf -- "$staging_directory"' EXIT INT TERM
staged_app="$staging_directory/MacEase.app"
executable_path="$staged_app/Contents/MacOS/MacEase"
framework_path="$staged_app/Contents/Frameworks/Sparkle.framework"

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Frameworks"
install -m 755 "$bin_path/MacEase" "$executable_path"
cp "$info_plist" "$staged_app/Contents/Info.plist"
ditto "$bin_path/Sparkle.framework" "$framework_path"
plutil -replace CFBundleShortVersionString -string "$short_version" \
  "$staged_app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" \
  "$staged_app/Contents/Info.plist"
plutil -lint "$staged_app/Contents/Info.plist" >/dev/null

# A development package does not enable Hardened Runtime: Sparkle documents
# that ad-hoc signatures cannot satisfy runtime library validation.
codesign --force --sign - --entitlements "$entitlements" "$staged_app"

codesign --verify --deep --strict --verbose=2 "$staged_app"
[[ $(lipo -archs "$executable_path") == arm64 ]] \
  || die "the packaged executable is not arm64-only"
otool -L "$executable_path" | grep -F \
  '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null \
  || die "the executable does not link the embedded Sparkle framework"

if [[ -e "$app_path" || -L "$app_path" ]]; then
  rm -rf -- "$app_path"
fi
mv "$staged_app" "$app_path"
rmdir "$staging_directory"
trap - EXIT INT TERM

file "$app_path/Contents/MacOS/MacEase"
print -r -- "$app_path"
