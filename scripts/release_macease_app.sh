#!/bin/zsh
set -euo pipefail

release_script=${0:A}
repo_root=${release_script:h:h}
package_root="$repo_root/Packages/MacEaseCore"
info_plist="$repo_root/Support/MacEase-Info.plist"
entitlements="$repo_root/Support/MacEase.entitlements"
package_script="$repo_root/scripts/package_macease_app.sh"
license_file="$repo_root/LICENSE"
third_party_notices="$repo_root/THIRD_PARTY_NOTICES.txt"
sparkle_tools="$package_root/.build/artifacts/sparkle/Sparkle/bin"
user_home_directory=${HOME:-}
if [[ -n "$user_home_directory" ]]; then
  user_home_directory=${user_home_directory:A}
fi
temporary_root=${TMPDIR:-/tmp}
temporary_root=${temporary_root:A}

usage() {
  print -r -- "usage: $0 COMMAND [arguments]"
  print -r -- "commands:"
  print -r -- "  verify-config"
  print -r -- "  preflight"
  print -r -- "  verify-app APP"
  print -r -- "  sign APP"
  print -r -- "  archive APP OUTPUT.zip"
  print -r -- "  notarize OUTPUT.zip"
  print -r -- "  wait SUBMISSION_ID"
  print -r -- "  staple APP"
  print -r -- "  appcast UPDATES_DIRECTORY"
  print -r -- "  metadata APP OUTPUT.zip OUTPUT_DIRECTORY"
}

die() {
  print -u2 -r -- "error: $1"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required tool is unavailable: $1"
}

require_argument_count() {
  [[ "$2" == "$3" ]] || die "$1 requires $3 argument(s)"
}

validate_https_url() {
  local label=$1
  local value=$2
  local authority=${value#https://}
  authority=${authority%%/*}
  [[ "$value" == https://* ]] || die "$label must use HTTPS"
  [[ -n "$authority" && "$authority" != *"@"* ]] \
    || die "$label must have a host and no embedded credentials"
  [[ "$value" != *[[:space:]]* && "$value" != *'"'* && "$value" != *"'"* \
    && "$value" != *'?'* && "$value" != *'#'* && "$value" != *\\* ]] \
    || die "$label contains an unsafe character"
}

validate_output_directory() {
  local directory=$1
  [[ -n "$directory" ]] || die "an explicit output directory is required"
  directory=${directory:A}
  [[ "$directory" != / && "$directory" != "$repo_root" \
    && ( -z "$user_home_directory" || "$directory" != "$user_home_directory" ) ]] \
    || die "refusing to use a broad output directory"
  mkdir -p -- "$directory"
  directory=${directory:A}
  [[ -d "$directory" && -w "$directory" ]] || die "output directory is not writable"
  print -r -- "$directory"
}

validate_temporary_directory() {
  local directory=${1:A}
  local expected_prefix=$2
  [[ -d "$directory" && "$directory:h" == "$temporary_root" \
    && "$directory:t" == "$expected_prefix".* ]] \
    || die "temporary directory did not resolve safely"
  print -r -- "$directory"
}

validate_app() {
  local app=${1:A}
  [[ -d "$app" && "$app:t" == MacEase.app ]] || die "expected an existing MacEase.app"
  [[ -x "$app/Contents/MacOS/MacEase" ]] || die "MacEase executable is missing"
  [[ -f "$app/Contents/Info.plist" ]] || die "Info.plist is missing"
  [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] \
    || die "Sparkle.framework is missing"
  [[ -s "$app/Contents/Resources/LICENSE.txt" ]] || die "LICENSE.txt is missing or empty"
  [[ -s "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt" ]] \
    || die "THIRD_PARTY_NOTICES.txt is missing or empty"
  cmp -s "$third_party_notices" "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt" \
    || die "the app's third-party notices do not match the repository file"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  [[ $(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist") \
    == com.macease.app ]] || die "unexpected bundle identifier"
  [[ $(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist") \
    == 15.0 ]] || die "unexpected deployment target"
  [[ $(plutil -extract SUEnableInstallerLauncherService raw \
    "$app/Contents/Info.plist") == true ]] \
    || die "Sparkle's sandboxed installer service is disabled"
  [[ $(lipo -archs "$app/Contents/MacOS/MacEase") == arm64 ]] \
    || die "MacEase is not arm64-only"
  [[ $(lipo -archs "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle") \
    == arm64 ]] || die "Sparkle.framework is not arm64-only"
  otool -L "$app/Contents/MacOS/MacEase" | grep -F \
    '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null \
    || die "MacEase does not link its embedded Sparkle framework"
  codesign --verify --deep --strict "$app"
}

validate_signed_entitlements() {
  local app=$1
  local extracted
  extracted=$(mktemp "${TMPDIR:-/tmp}/macease-entitlements.XXXXXX") \
    || die "could not create an entitlement validation file"
  if ! codesign -d --entitlements "$extracted" "$app" 2>/dev/null; then
    rm -f -- "$extracted"
    die "could not read the signed entitlements"
  fi
  local failure=
  if [[ $(plutil -extract 'com\.apple\.security\.app-sandbox' raw "$extracted") != true ]]; then
    failure="${failure}${failure:+; }the signed app is not sandboxed"
  fi
  if [[ $(plutil -extract 'com\.apple\.security\.network\.client' raw "$extracted") != true ]]; then
    failure="${failure}${failure:+; }the signed app lacks outgoing network access"
  fi
  if [[ $(plutil -extract \
    'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name.0' raw \
    "$extracted") != com.macease.app-spks ]]; then
    failure="${failure}${failure:+; }the signed app lacks Sparkle's status mach lookup"
  fi
  if [[ $(plutil -extract \
    'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name.1' raw \
    "$extracted") != com.macease.app-spki ]]; then
    failure="${failure}${failure:+; }the signed app lacks Sparkle's installer mach lookup"
  fi
  rm -f -- "$extracted"
  [[ -z "$failure" ]] || die "$failure"
}

validate_release_sparkle_configuration() {
  local app=$1
  local expected_feed_url=$2
  local expected_public_key=$3
  local plist="$app/Contents/Info.plist"
  local actual_feed_url
  local actual_public_key
  actual_feed_url=$(plutil -extract SUFeedURL raw "$plist" 2>/dev/null) \
    || die "the signed app has no Sparkle appcast URL"
  actual_public_key=$(plutil -extract SUPublicEDKey raw "$plist" 2>/dev/null) \
    || die "the signed app has no Sparkle public key"
  [[ "$actual_feed_url" == "$expected_feed_url" ]] \
    || die "the signed app's Sparkle appcast URL does not match the release configuration"
  [[ "$actual_public_key" == "$expected_public_key" ]] \
    || die "the signed app's Sparkle public key does not match the release key"
}

verify_distribution_signature() {
  local app=$1
  local expected_team_id=${2:-}
  local details
  details=$(codesign -d --verbose=4 "$app" 2>&1)
  print -r -- "$details" | grep -F 'Authority=Developer ID Application:' >/dev/null \
    || die "the app is not signed with Developer ID Application"
  print -r -- "$details" | grep -E '^flags=.*runtime' >/dev/null \
    || die "Hardened Runtime is not enabled"
  local team
  team=$(print -r -- "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')
  [[ -n "$team" && "$team" != "not set" ]] || die "the signature has no Team ID"
  [[ -z "$expected_team_id" || "$team" == "$expected_team_id" ]] \
    || die "the signed Team ID does not match the release Team ID"
  validate_signed_entitlements "$app"
}

verify_config() {
  require_command plutil
  require_command codesign
  require_command lipo
  require_command otool
  [[ -f "$info_plist" && -f "$entitlements" ]] || die "support configuration is missing"
  [[ -s "$license_file" ]] || die "LICENSE is missing or empty"
  [[ -s "$third_party_notices" ]] || die "third-party notices are missing or empty"
  plutil -lint "$info_plist" "$entitlements" >/dev/null
  [[ $(plutil -extract SUEnableInstallerLauncherService raw "$info_plist") == true ]] \
    || die "SUEnableInstallerLauncherService must be true"
  [[ $(plutil -extract 'com\.apple\.security\.app-sandbox' raw "$entitlements") == true ]] \
    || die "App Sandbox must be enabled"
  [[ $(plutil -extract 'com\.apple\.security\.network\.client' raw "$entitlements") == true ]] \
    || die "outgoing network access must be enabled"
  [[ $(plutil -extract \
    'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name.0' raw \
    "$entitlements") == com.macease.app-spks ]] \
    || die "Sparkle status mach lookup is missing"
  [[ $(plutil -extract \
    'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name.1' raw \
    "$entitlements") == com.macease.app-spki ]] \
    || die "Sparkle installer mach lookup is missing"
  if plutil -extract SUFeedURL raw "$info_plist" >/dev/null 2>&1 \
    || plutil -extract SUPublicEDKey raw "$info_plist" >/dev/null 2>&1; then
    die "release-specific Sparkle values must not be committed to Info.plist"
  fi
  zsh -n "$package_script"
  zsh -n "$release_script"
  "$package_script" --check >/dev/null
  print -r -- "Release configuration is valid; no signing, notarization, or upload ran."
}

preflight() {
  verify_config >/dev/null
  local missing=()
  [[ -n "${MACEASE_SIGNING_IDENTITY:-}" ]] || missing+=(MACEASE_SIGNING_IDENTITY)
  [[ -n "${MACEASE_TEAM_ID:-}" ]] || missing+=(MACEASE_TEAM_ID)
  [[ -n "${MACEASE_SPARKLE_FEED_URL:-}" ]] || missing+=(MACEASE_SPARKLE_FEED_URL)
  [[ -n "${MACEASE_SPARKLE_PUBLIC_KEY:-}" ]] || missing+=(MACEASE_SPARKLE_PUBLIC_KEY)
  [[ -n "${MACEASE_NOTARY_PROFILE:-}" ]] || missing+=(MACEASE_NOTARY_PROFILE)
  [[ -n "${MACEASE_SPARKLE_KEYCHAIN_ACCOUNT:-}" ]] \
    || missing+=(MACEASE_SPARKLE_KEYCHAIN_ACCOUNT)
  [[ -n "${MACEASE_RELEASE_DOWNLOAD_PREFIX:-}" ]] \
    || missing+=(MACEASE_RELEASE_DOWNLOAD_PREFIX)
  [[ -n "${MACEASE_RELEASE_URL:-}" ]] || missing+=(MACEASE_RELEASE_URL)
  [[ -n "${MACEASE_HOMEPAGE_URL:-}" ]] || missing+=(MACEASE_HOMEPAGE_URL)
  if (( ${#missing} > 0 )); then
    print -u2 -r -- "release preflight stopped; missing material names:"
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
  local identity=$MACEASE_SIGNING_IDENTITY
  local team_id=$MACEASE_TEAM_ID
  local feed_url=$MACEASE_SPARKLE_FEED_URL
  local public_key=$MACEASE_SPARKLE_PUBLIC_KEY
  local team_pattern='^[A-Z0-9]{10}$'
  [[ "$identity" == 'Developer ID Application:'* ]] \
    || die "MACEASE_SIGNING_IDENTITY must name a Developer ID Application certificate"
  [[ "$team_id" =~ $team_pattern && "$identity" == *"($team_id)"* ]] \
    || die "the signing identity and 10-character Team ID do not match"
  "$package_script" --check --identity "$identity" --feed-url "$feed_url" \
    --public-key "$public_key" >/dev/null
  validate_https_url "release download prefix" "$MACEASE_RELEASE_DOWNLOAD_PREFIX"
  validate_https_url "release URL" "$MACEASE_RELEASE_URL"
  validate_https_url "homepage URL" "$MACEASE_HOMEPAGE_URL"
  print -r -- "Release material names are present; no external action ran."
}

sign_app() {
  preflight >/dev/null
  local app=${1:A}
  validate_app "$app"
  local identity=${MACEASE_SIGNING_IDENTITY:-}
  local team_id=${MACEASE_TEAM_ID:-}
  local feed_url=${MACEASE_SPARKLE_FEED_URL:-}
  local public_key=${MACEASE_SPARKLE_PUBLIC_KEY:-}
  [[ -n "$identity" ]] || die "MACEASE_SIGNING_IDENTITY is required"
  [[ "$identity" == 'Developer ID Application:'* ]] \
    || die "MACEASE_SIGNING_IDENTITY must name a Developer ID Application certificate"
  team_pattern='^[A-Z0-9]{10}$'
  [[ "$team_id" =~ $team_pattern ]] || die "MACEASE_TEAM_ID must be a 10-character Team ID"
  [[ "$identity" == *"($team_id)"* ]] \
    || die "the signing identity does not name MACEASE_TEAM_ID"
  [[ -n "$feed_url" && -n "$public_key" ]] \
    || die "the Sparkle appcast URL and public key are required before signing"
  "$package_script" --check --identity "$identity" --feed-url "$feed_url" \
    --public-key "$public_key" >/dev/null
  security find-identity -v -p codesigning | grep -F -- "\"$identity\"" >/dev/null \
    || die "the requested Developer ID Application identity is unavailable"

  local plist="$app/Contents/Info.plist"
  if plutil -extract SUFeedURL raw "$plist" >/dev/null 2>&1; then
    plutil -replace SUFeedURL -string "$feed_url" "$plist"
  else
    plutil -insert SUFeedURL -string "$feed_url" "$plist"
  fi
  if plutil -extract SUPublicEDKey raw "$plist" >/dev/null 2>&1; then
    plutil -replace SUPublicEDKey -string "$public_key" "$plist"
  else
    plutil -insert SUPublicEDKey -string "$public_key" "$plist"
  fi

  local framework="$app/Contents/Frameworks/Sparkle.framework"
  local sparkle_version="$framework/Versions/B"
  local sign_args=(--force --sign "$identity" --options runtime --timestamp)
  codesign "${sign_args[@]}" "$sparkle_version/XPCServices/Installer.xpc"
  codesign "${sign_args[@]}" --preserve-metadata=entitlements \
    "$sparkle_version/XPCServices/Downloader.xpc"
  codesign "${sign_args[@]}" "$sparkle_version/Autoupdate"
  codesign "${sign_args[@]}" "$sparkle_version/Updater.app"
  codesign "${sign_args[@]}" "$framework"
  codesign "${sign_args[@]}" --entitlements "$entitlements" "$app"
  validate_app "$app"
  verify_distribution_signature "$app" "$team_id"
  validate_release_sparkle_configuration "$app" "$feed_url" "$public_key"
  local actual_team
  actual_team=$(codesign -d --verbose=4 "$app" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{print $2; exit}')
  [[ "$actual_team" == "$team_id" ]] || die "the signed Team ID does not match"
  print -r -- "Developer ID signing and Hardened Runtime verification succeeded."
}

archive_app() {
  preflight >/dev/null
  local app=${1:A}
  local archive=${2:A}
  validate_app "$app"
  verify_distribution_signature "$app" "$MACEASE_TEAM_ID"
  validate_release_sparkle_configuration \
    "$app" "$MACEASE_SPARKLE_FEED_URL" "$MACEASE_SPARKLE_PUBLIC_KEY"
  [[ "$archive" == *.zip && "$archive:t" != .zip ]] || die "output must be an explicit .zip path"
  [[ ! -e "$archive" && ! -L "$archive" ]] || die "archive already exists"
  local parent
  parent=$(validate_output_directory "$archive:h")
  [[ "$archive:h" == "$parent" ]] || die "archive output path did not resolve safely"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  [[ -s "$archive" ]] || die "the archive was not created"
  print -r -- "$archive"
}

validate_release_archive() {
  local archive=${1:A}
  local requires_staple=$2
  local expected_feed_url=${3:-}
  local expected_public_key=${4:-}
  local expected_team_id=${5:-}
  [[ -f "$archive" && "$archive" == *.zip ]] || die "an existing .zip archive is required"
  local staging
  staging=$(mktemp -d "${TMPDIR:-/tmp}/macease-archive.XXXXXX") \
    || die "could not create an archive validation directory"
  staging=$(validate_temporary_directory "$staging" macease-archive)
  trap 'rm -rf -- "$staging"' EXIT INT TERM
  ditto -x -k "$archive" "$staging" || die "the release archive could not be extracted"
  [[ -d "$staging/MacEase.app" ]] || die "the archive does not contain MacEase.app"
  validate_app "$staging/MacEase.app"
  verify_distribution_signature "$staging/MacEase.app" "$expected_team_id"
  if [[ -n "$expected_feed_url" || -n "$expected_public_key" ]]; then
    [[ -n "$expected_feed_url" && -n "$expected_public_key" ]] \
      || die "both expected Sparkle values are required for archive validation"
    validate_release_sparkle_configuration \
      "$staging/MacEase.app" "$expected_feed_url" "$expected_public_key"
  fi
  if $requires_staple; then
    xcrun stapler validate "$staging/MacEase.app" >/dev/null \
      || die "the archived app has no valid notarization ticket"
  fi
  rm -rf -- "$staging"
  trap - EXIT INT TERM
}

notarize_archive() {
  preflight >/dev/null
  local archive=${1:A}
  local profile=${MACEASE_NOTARY_PROFILE:-}
  [[ -n "$profile" ]] || die "MACEASE_NOTARY_PROFILE is required"
  validate_release_archive "$archive" false "$MACEASE_SPARKLE_FEED_URL" \
    "$MACEASE_SPARKLE_PUBLIC_KEY" "$MACEASE_TEAM_ID"
  local result
  if ! result=$(xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait 2>&1); then
    print -u2 -r -- "$result"
    return 1
  fi
  print -r -- "$result"
  [[ "$result" == *Accepted* ]] || die "notarization did not report Accepted"
}

wait_for_notarization() {
  preflight >/dev/null
  local submission_id=$1
  local profile=${MACEASE_NOTARY_PROFILE:-}
  uuid_pattern='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  [[ "$submission_id" =~ $uuid_pattern ]] || die "a notarization submission UUID is required"
  [[ -n "$profile" ]] || die "MACEASE_NOTARY_PROFILE is required"
  xcrun notarytool wait "$submission_id" --keychain-profile "$profile"
}

staple_app() {
  preflight >/dev/null
  local app=${1:A}
  validate_app "$app"
  verify_distribution_signature "$app" "$MACEASE_TEAM_ID"
  validate_release_sparkle_configuration \
    "$app" "$MACEASE_SPARKLE_FEED_URL" "$MACEASE_SPARKLE_PUBLIC_KEY"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
}

generate_appcast() {
  preflight >/dev/null
  local updates_directory=${1:A}
  local account=${MACEASE_SPARKLE_KEYCHAIN_ACCOUNT:-}
  local download_prefix=${MACEASE_RELEASE_DOWNLOAD_PREFIX:-}
  local feed_url=${MACEASE_SPARKLE_FEED_URL:-}
  local public_key=${MACEASE_SPARKLE_PUBLIC_KEY:-}
  [[ -d "$updates_directory" && "$updates_directory" != / \
    && "$updates_directory" != "$repo_root" ]] \
    || die "an explicit updates directory is required"
  local archives=("$updates_directory"/*.zip(N))
  (( ${#archives} > 0 )) || die "the updates directory contains no .zip archive"
  [[ -n "$account" ]] || die "MACEASE_SPARKLE_KEYCHAIN_ACCOUNT is required"
  [[ -n "$download_prefix" ]] || die "MACEASE_RELEASE_DOWNLOAD_PREFIX is required"
  [[ -n "$feed_url" ]] || die "MACEASE_SPARKLE_FEED_URL is required"
  [[ -n "$public_key" ]] || die "MACEASE_SPARKLE_PUBLIC_KEY is required"
  validate_https_url "release download prefix" "$download_prefix"
  validate_https_url "Sparkle appcast URL" "$feed_url"
  [[ "$feed_url" == */appcast.xml ]] \
    || die "MACEASE_SPARKLE_FEED_URL must identify appcast.xml"
  local archive
  for archive in "${archives[@]}"; do
    validate_release_archive \
      "$archive" true "$feed_url" "$public_key" "$MACEASE_TEAM_ID"
  done
  [[ -x "$sparkle_tools/generate_appcast" ]] \
    || die "Sparkle's generate_appcast tool is unavailable; resolve the Swift package first"
  [[ -x "$sparkle_tools/generate_keys" ]] \
    || die "Sparkle's generate_keys tool is unavailable; resolve the Swift package first"
  local stored_public_key
  stored_public_key=$("$sparkle_tools/generate_keys" -p --account "$account") \
    || die "the named Sparkle private key is unavailable in Keychain"
  [[ "$stored_public_key" == "$public_key" ]] \
    || die "the Sparkle Keychain key does not match the public key injected into MacEase"
  "$sparkle_tools/generate_appcast" --account "$account" \
    --download-url-prefix "$download_prefix" "$updates_directory"
}

generate_metadata() {
  preflight >/dev/null
  local app=${1:A}
  local archive=${2:A}
  validate_app "$app"
  verify_distribution_signature "$app" "$MACEASE_TEAM_ID"
  validate_release_sparkle_configuration \
    "$app" "$MACEASE_SPARKLE_FEED_URL" "$MACEASE_SPARKLE_PUBLIC_KEY"
  xcrun stapler validate "$app" >/dev/null
  [[ -f "$archive" && "$archive" == *.zip ]] || die "an existing .zip archive is required"
  local release_url=${MACEASE_RELEASE_URL:-}
  local homepage_url=${MACEASE_HOMEPAGE_URL:-}
  [[ -n "$release_url" && -n "$homepage_url" ]] \
    || die "MACEASE_RELEASE_URL and MACEASE_HOMEPAGE_URL are required"
  validate_https_url "release URL" "$release_url"
  validate_https_url "homepage URL" "$homepage_url"
  local url_path=${release_url%%\?*}
  [[ "$url_path:t" == "$archive:t" ]] \
    || die "the release URL filename does not match the archive"

  local archive_staging
  archive_staging=$(mktemp -d "${TMPDIR:-/tmp}/macease-archive.XXXXXX") \
    || die "could not create an archive validation directory"
  archive_staging=$(validate_temporary_directory "$archive_staging" macease-archive)
  trap 'rm -rf -- "$archive_staging"' EXIT INT TERM
  if ! ditto -x -k "$archive" "$archive_staging" \
    || [[ ! -d "$archive_staging/MacEase.app" ]]; then
    rm -rf -- "$archive_staging"
    die "the archive does not contain MacEase.app"
  fi
  validate_app "$archive_staging/MacEase.app"
  verify_distribution_signature "$archive_staging/MacEase.app" "$MACEASE_TEAM_ID"
  validate_release_sparkle_configuration \
    "$archive_staging/MacEase.app" "$MACEASE_SPARKLE_FEED_URL" \
    "$MACEASE_SPARKLE_PUBLIC_KEY"
  xcrun stapler validate "$archive_staging/MacEase.app" >/dev/null
  local app_hash
  local archived_hash
  app_hash=$(codesign -d --verbose=4 "$app" 2>&1 \
    | awk -F= '/^CDHash=/{print $2; exit}')
  archived_hash=$(codesign -d --verbose=4 "$archive_staging/MacEase.app" 2>&1 \
    | awk -F= '/^CDHash=/{print $2; exit}')
  rm -rf -- "$archive_staging"
  trap - EXIT INT TERM
  [[ -n "$app_hash" && "$app_hash" == "$archived_hash" ]] \
    || die "the archive does not contain the supplied signed app"

  local output_directory
  output_directory=$(validate_output_directory "$3")

  local metadata="$output_directory/release-metadata.json"
  local cask="$output_directory/macease.rb"
  [[ ! -e "$metadata" && ! -e "$cask" ]] \
    || die "release metadata output already exists"
  local version
  local build
  version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
  build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
  local version_pattern='^[0-9]+([.][0-9]+){1,3}([-.][0-9A-Za-z]+)*$'
  local build_pattern='^[1-9][0-9]*$'
  [[ "$version" =~ $version_pattern ]] || die "the app has an invalid short version"
  [[ "$build" =~ $build_pattern ]] || die "the app has an invalid build number"
  local sha256
  sha256=$(shasum -a 256 "$archive" | awk '{print $1}')

  local metadata_plist
  metadata_plist=$(mktemp "${TMPDIR:-/tmp}/macease-release.XXXXXX") \
    || die "could not create metadata staging file"
  plutil -create xml1 "$metadata_plist"
  plutil -insert version -string "$version" "$metadata_plist"
  plutil -insert build -string "$build" "$metadata_plist"
  plutil -insert architecture -string arm64 "$metadata_plist"
  plutil -insert minimumMacOS -string 15.0 "$metadata_plist"
  plutil -insert archive -string "$archive:t" "$metadata_plist"
  plutil -insert sha256 -string "$sha256" "$metadata_plist"
  plutil -insert releaseURL -string "$release_url" "$metadata_plist"
  plutil -convert json -r -o "$metadata" "$metadata_plist"
  rm -f -- "$metadata_plist"

  {
    printf 'cask "macease" do\n'
    printf '  version "%s"\n' "$version"
    printf '  sha256 "%s"\n\n' "$sha256"
    printf '  url "%s"\n' "$release_url"
    printf '  name "MacEase"\n'
    printf '  desc "Native macOS client for NetEase Cloud Music"\n'
    printf '  homepage "%s"\n\n' "$homepage_url"
    printf '  auto_updates true\n'
    printf '  depends_on arch: :arm64\n'
    printf '  depends_on macos: :sequoia\n\n'
    printf '  app "MacEase.app"\n'
    printf 'end\n'
  } > "$cask"
  print -r -- "$metadata"
  print -r -- "$cask"
}

command_name=${1:-}
[[ -n "$command_name" ]] || {
  usage
  exit 2
}
shift

case "$command_name" in
  verify-config)
    require_argument_count "$command_name" "$#" 0
    verify_config
    ;;
  preflight)
    require_argument_count "$command_name" "$#" 0
    preflight
    ;;
  verify-app)
    require_argument_count "$command_name" "$#" 1
    validate_app "$1"
    print -r -- "App structure, architecture, linkage, and nested signatures are valid."
    ;;
  sign)
    require_argument_count "$command_name" "$#" 1
    sign_app "$1"
    ;;
  archive)
    require_argument_count "$command_name" "$#" 2
    archive_app "$1" "$2"
    ;;
  notarize)
    require_argument_count "$command_name" "$#" 1
    notarize_archive "$1"
    ;;
  wait)
    require_argument_count "$command_name" "$#" 1
    wait_for_notarization "$1"
    ;;
  staple)
    require_argument_count "$command_name" "$#" 1
    staple_app "$1"
    ;;
  appcast)
    require_argument_count "$command_name" "$#" 1
    generate_appcast "$1"
    ;;
  metadata)
    require_argument_count "$command_name" "$#" 3
    generate_metadata "$1" "$2" "$3"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    print -u2 -r -- "unknown command: $command_name"
    usage >&2
    exit 2
    ;;
esac
