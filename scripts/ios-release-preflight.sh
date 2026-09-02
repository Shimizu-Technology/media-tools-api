#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

archive_path=""
export_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      archive_path="${2:-}"
      [[ -n "$archive_path" ]] || { echo "--archive requires a path"; exit 1; }
      shift 2
      ;;
    --export)
      export_path="${2:-}"
      [[ -n "$export_path" ]] || { echo "--export requires a path"; exit 1; }
      shift 2
      ;;
    *)
      echo "Usage: $0 [--archive /path/to/MediaTools.xcarchive] [--export /path/to/AppStoreExport]"
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS release preflight requires macOS"
  exit 1
fi

for command_name in xcodebuild xcrun plutil ruby sips codesign security unzip curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name"
    exit 1
  fi
done

project_path="ios/MediaTools/MediaTools.xcodeproj"
scheme="MediaTools"
info_plist="ios/MediaTools/MediaTools/Info.plist"
privacy_manifest="ios/MediaTools/MediaTools/PrivacyInfo.xcprivacy"
entitlements_path="ios/MediaTools/MediaTools/MediaTools.entitlements"
metadata_path="ios/app-store/en-US"
native_auth_release_path="ios/app-store/native-auth-release.json"

for required_path in "$project_path" "$info_plist" "$privacy_manifest" "$entitlements_path" "$metadata_path" "$native_auth_release_path"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Missing release input: $required_path"
    exit 1
  fi
done

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
if (( xcode_major < 26 || sdk_major < 26 )); then
  echo "App Store uploads require Xcode/iOS SDK 26 or later; found Xcode $xcode_version and iOS SDK $sdk_version"
  exit 1
fi

release_settings="$(xcodebuild \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration Release \
  -showBuildSettings 2>/dev/null)"

build_setting() {
  local setting_name="$1"
  awk -F ' = ' -v setting_name="$setting_name" '
    $1 ~ "^[[:space:]]*" setting_name "$" && !found {
      value = $2
      found = 1
    }
    END { if (found) print value }
  ' <<<"$release_settings"
}

bundle_id="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
team_id="$(build_setting DEVELOPMENT_TEAM)"
marketing_version="$(build_setting MARKETING_VERSION)"
build_number="$(build_setting CURRENT_PROJECT_VERSION)"
configured_entitlements="$(build_setting CODE_SIGN_ENTITLEMENTS)"
clerk_key="$(build_setting CLERK_PUBLISHABLE_KEY)"

[[ "$bundle_id" == "com.ShimizuTechnology.MediaTools" ]] || { echo "Unexpected bundle ID: $bundle_id"; exit 1; }
[[ "$team_id" == "4T358A5S74" ]] || { echo "Unexpected Apple team: $team_id"; exit 1; }
[[ "$marketing_version" == "1.0" ]] || { echo "Unexpected marketing version: $marketing_version"; exit 1; }
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo "Build number is not numeric: $build_number"; exit 1; }
(( build_number >= 10 )) || { echo "Build number must be 10 or later; found $build_number"; exit 1; }
[[ "$configured_entitlements" == "MediaTools/MediaTools.entitlements" ]] || { echo "Unexpected entitlements setting: $configured_entitlements"; exit 1; }
[[ -n "$clerk_key" ]] || { echo "Release build is missing CLERK_PUBLISHABLE_KEY"; exit 1; }

if [[ "$clerk_key" == pk_test_* ]]; then
  echo "Notice: the Release target uses the owner-approved Clerk development instance"
fi

IOS_SOURCE_ROOT="ios/MediaTools/MediaTools" IOS_INFO_PLIST="$info_plist" ruby <<'RUBY'
root = ENV.fetch("IOS_SOURCE_ROOT")
info_plist = ENV.fetch("IOS_INFO_PLIST")
forbidden = ["Allow microphone", "Enable completion alerts"]
release_inputs = Dir.glob(File.join(root, "**", "*.swift")) + [info_plist]
offenders = release_inputs.filter do |path|
  forbidden.any? { |copy| File.read(path, encoding: "UTF-8").include?(copy) }
end
abort "Permission education must use neutral action labels such as Continue or Next: #{offenders.join(', ')}" unless offenders.empty?
RUBY

clerk_frontend_api="$(CLERK_KEY="$clerk_key" ruby <<'RUBY'
require "base64"
key = ENV.fetch("CLERK_KEY")
encoded = key.sub(/\Apk_(?:test|live)_/, "")
decoded = Base64.urlsafe_decode64(encoded).delete_suffix("$")
abort "Invalid Clerk publishable key payload" unless decoded.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i)
puts "https://#{decoded}"
RUBY
)"

# This public host identifies the Clerk instance that is configured for this
# app's API and native Apple registration. Pinning it prevents a different
# development tenant with superficially similar providers from being shipped.
approved_clerk_frontend_api="https://welcomed-earwig-86.clerk.accounts.dev"
[[ "$clerk_frontend_api" == "$approved_clerk_frontend_api" ]] || {
  echo "Release build uses an unapproved Clerk tenant: $clerk_frontend_api"
  exit 1
}

CLERK_FRONTEND_API="$clerk_frontend_api" \
APPLE_TEAM_ID="$team_id" \
APP_BUNDLE_ID="$bundle_id" \
NATIVE_AUTH_RELEASE_PATH="$native_auth_release_path" ruby <<'RUBY'
require "date"
require "json"

attestation = JSON.parse(File.read(ENV.fetch("NATIVE_AUTH_RELEASE_PATH"), encoding: "UTF-8"))
abort "Clerk native-app mapping is not confirmed for this release" unless attestation["appleNativeMappingConfirmed"] == true
abort "Native-auth attestation has the wrong Clerk tenant" unless attestation["clerkFrontendAPI"] == ENV.fetch("CLERK_FRONTEND_API")
abort "Native-auth attestation has the wrong Apple team" unless attestation["appleTeamID"] == ENV.fetch("APPLE_TEAM_ID")
abort "Native-auth attestation has the wrong bundle ID" unless attestation["bundleID"] == ENV.fetch("APP_BUNDLE_ID")
expected_source = "Clerk Dashboard > Configure > Native applications"
abort "Native-auth attestation was not confirmed in Clerk's Native applications dashboard" unless attestation["confirmationSource"] == expected_source
# `confirmedOn` is intentionally an ISO 8601 calendar date, not an event timestamp.
Date.iso8601(attestation.fetch("confirmedOn"))
RUBY

clerk_environment="$(curl --fail --silent --show-error --max-time 15 "$clerk_frontend_api/v1/environment")"
CLERK_ENVIRONMENT="$clerk_environment" ruby <<'RUBY'
require "json"
environment = JSON.parse(ENV.fetch("CLERK_ENVIRONMENT"))
strategies = environment.fetch("auth_config").fetch("identification_strategies")
abort "Shipping Clerk environment does not offer Sign in with Apple" unless strategies.include?("oauth_apple")
abort "Shipping Clerk environment unexpectedly dropped Google sign-in" unless strategies.include?("oauth_google")
RUBY

if ! apple_sign_in_mode="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$entitlements_path" 2>/dev/null)"; then
  echo "Sign in with Apple entitlement is missing"
  exit 1
fi
[[ "$apple_sign_in_mode" == "Default" ]] || { echo "Unexpected Sign in with Apple mode: $apple_sign_in_mode"; exit 1; }

encryption_exempt="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info_plist")"
microphone_copy="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist")"
background_mode="$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' "$info_plist")"
[[ "$encryption_exempt" == "false" ]] || { echo "ITSAppUsesNonExemptEncryption must be false"; exit 1; }
[[ -n "$microphone_copy" ]] || { echo "Microphone usage description is empty"; exit 1; }
[[ "$background_mode" == "audio" ]] || { echo "The recording app must declare the audio background mode"; exit 1; }

plutil -lint "$info_plist" "$privacy_manifest" "$entitlements_path" >/dev/null

plutil -convert json -o - "$privacy_manifest" | ruby -rjson -e '
  manifest = JSON.parse(STDIN.read)
  abort "Privacy manifest must declare no tracking" unless manifest["NSPrivacyTracking"] == false

  expected = %w[
    NSPrivacyCollectedDataTypeName
    NSPrivacyCollectedDataTypeEmailAddress
    NSPrivacyCollectedDataTypeUserID
    NSPrivacyCollectedDataTypeAudioData
    NSPrivacyCollectedDataTypeOtherUserContent
  ]
  entries = manifest.fetch("NSPrivacyCollectedDataTypes")
  indexed = entries.to_h { |entry| [entry.fetch("NSPrivacyCollectedDataType"), entry] }
  abort "Privacy manifest data types do not match the release disclosure" unless indexed.keys.sort == expected.sort

  expected.each do |data_type|
    entry = indexed.fetch(data_type)
    abort "#{data_type} must be linked to the account" unless entry["NSPrivacyCollectedDataTypeLinked"] == true
    abort "#{data_type} must not be used for tracking" unless entry["NSPrivacyCollectedDataTypeTracking"] == false
    purposes = entry.fetch("NSPrivacyCollectedDataTypePurposes")
    abort "#{data_type} must be limited to app functionality" unless purposes == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
  end
'

icon_path="ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
icon_width="$(sips -g pixelWidth "$icon_path" | awk '/pixelWidth/ { print $2 }')"
icon_height="$(sips -g pixelHeight "$icon_path" | awk '/pixelHeight/ { print $2 }')"
[[ "$icon_width" == "1024" && "$icon_height" == "1024" ]] || { echo "App icon must be 1024x1024; found ${icon_width}x${icon_height}"; exit 1; }

METADATA_PATH="$metadata_path" ruby <<'RUBY'
path = ENV.fetch("METADATA_PATH")
limits = {
  "name.txt" => 30,
  "subtitle.txt" => 30,
  "promotional_text.txt" => 170,
  "description.txt" => 4_000,
  "keywords.txt" => 100,
  "review_notes.txt" => 4_000
}

limits.each do |filename, limit|
  value = File.read(File.join(path, filename), encoding: "UTF-8").strip
  size = filename == "keywords.txt" || filename == "review_notes.txt" ? value.bytesize : value.length
  abort "#{filename} is empty" if value.empty?
  abort "#{filename} exceeds #{limit}" if size > limit
end

%w[support_url.txt marketing_url.txt privacy_url.txt privacy_choices_url.txt].each do |filename|
  value = File.read(File.join(path, filename), encoding: "UTF-8").strip
  abort "#{filename} must use HTTPS" unless value.start_with?("https://")
end
RUBY

if [[ -n "$archive_path" ]]; then
  if [[ ! -d "$archive_path" ]]; then
    echo "Archive not found: $archive_path"
    exit 1
  fi

  application_path="$(plutil -extract ApplicationProperties.ApplicationPath raw "$archive_path/Info.plist")"
  app_path="$archive_path/Products/$application_path"
  app_info="$app_path/Info.plist"
  if [[ ! -d "$app_path" ]]; then
    echo "Archived app not found: $app_path"
    exit 1
  fi

  [[ "$(plutil -extract CFBundleIdentifier raw "$app_info")" == "$bundle_id" ]] || { echo "Archived bundle ID does not match"; exit 1; }
  [[ "$(plutil -extract CFBundleShortVersionString raw "$app_info")" == "$marketing_version" ]] || { echo "Archived marketing version does not match"; exit 1; }
  [[ "$(plutil -extract CFBundleVersion raw "$app_info")" == "$build_number" ]] || { echo "Archived build number does not match"; exit 1; }
  archived_sdk="$(plutil -extract DTSDKName raw "$app_info")"
  [[ "$archived_sdk" == iphoneos26.* ]] || { echo "Archive was not built with the iOS 26 SDK: $archived_sdk"; exit 1; }
  [[ -f "$app_path/PrivacyInfo.xcprivacy" ]] || { echo "Archive is missing PrivacyInfo.xcprivacy"; exit 1; }

  preflight_tmp="$(mktemp -d)"
  trap 'rm -rf "$preflight_tmp"' EXIT
  codesign -d --entitlements :- "$app_path" >"$preflight_tmp/app-entitlements.plist" 2>/dev/null
  archived_apple_mode="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$preflight_tmp/app-entitlements.plist")"
  [[ "$archived_apple_mode" == "Default" ]] || { echo "Signed archive is missing Sign in with Apple"; exit 1; }

  if [[ -f "$app_path/embedded.mobileprovision" ]]; then
    security cms -D -i "$app_path/embedded.mobileprovision" >"$preflight_tmp/profile.plist"
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$preflight_tmp/profile.plist")"
    [[ "$profile_app_id" == "$team_id.$bundle_id" ]] || { echo "Provisioning profile app identifier does not match: $profile_app_id"; exit 1; }
  fi
fi

if [[ -n "$export_path" ]]; then
  distribution_summary="$export_path/DistributionSummary.plist"
  ipa_path="$export_path/MediaTools.ipa"
  if [[ ! -f "$distribution_summary" || ! -f "$ipa_path" ]]; then
    echo "App Store export is incomplete: $export_path"
    exit 1
  fi

  plutil -lint "$distribution_summary" >/dev/null
  unzip -tq "$ipa_path" >/dev/null

  summary_root=":MediaTools.ipa:0"
  exported_build="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:buildNumber" "$distribution_summary")"
  exported_version="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:versionNumber" "$distribution_summary")"
  exported_app_id="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:application-identifier" "$distribution_summary")"
  exported_get_task_allow="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:get-task-allow" "$distribution_summary")"
  exported_apple_mode="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:com.apple.developer.applesignin:0" "$distribution_summary")"
  exported_certificate="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:certificate:type" "$distribution_summary")"
  widget_build="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:0:buildNumber" "$distribution_summary")"
  widget_get_task_allow="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:0:entitlements:get-task-allow" "$distribution_summary")"

  [[ "$exported_build" == "$build_number" ]] || { echo "Exported build number does not match"; exit 1; }
  [[ "$exported_version" == "$marketing_version" ]] || { echo "Exported marketing version does not match"; exit 1; }
  [[ "$exported_app_id" == "$team_id.$bundle_id" ]] || { echo "Exported application identifier does not match"; exit 1; }
  [[ "$exported_get_task_allow" == "false" ]] || { echo "App Store export is debuggable"; exit 1; }
  [[ "$exported_apple_mode" == "Default" ]] || { echo "App Store export is missing Sign in with Apple"; exit 1; }
  [[ "$exported_certificate" == *"Apple Distribution"* ]] || { echo "App Store export is not distribution-signed: $exported_certificate"; exit 1; }
  [[ "$widget_build" == "$build_number" ]] || { echo "Widget build number does not match the app"; exit 1; }
  [[ "$widget_get_task_allow" == "false" ]] || { echo "Exported widget is debuggable"; exit 1; }
fi

echo "iOS release preflight passed for Media Tools $marketing_version ($build_number) with Xcode $xcode_version / iOS SDK $sdk_version"
