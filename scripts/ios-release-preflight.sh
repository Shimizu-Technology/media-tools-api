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

for command_name in xcodebuild xcrun plutil ruby sips codesign security unzip; do
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
share_entitlements_path="ios/MediaTools/ShareExtension/ShareExtension.entitlements"
metadata_path="ios/app-store/en-US"
export_options_path="ios/app-store/ExportOptions.plist"
app_group="group.com.shimizu-technology.media-tools"

for required_path in "$project_path" "$info_plist" "$privacy_manifest" "$entitlements_path" "$share_entitlements_path" "$metadata_path" "$export_options_path"; do
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

[[ "$bundle_id" == "com.ShimizuTechnology.MediaTools" ]] || { echo "Unexpected bundle ID: $bundle_id"; exit 1; }
[[ "$team_id" == "4T358A5S74" ]] || { echo "Unexpected Apple team: $team_id"; exit 1; }
[[ "$marketing_version" == "1.0" ]] || { echo "Unexpected marketing version: $marketing_version"; exit 1; }
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo "Build number is not numeric: $build_number"; exit 1; }
(( build_number >= 10 )) || { echo "Build number must be 10 or later; found $build_number"; exit 1; }
[[ "$configured_entitlements" == "MediaTools/MediaTools.entitlements" ]] || { echo "Unexpected entitlements setting: $configured_entitlements"; exit 1; }

# Media Tools owns its sign-in. The only thing left of the retired provider is the
# ability to read a session an older build stored, so these checks are specific:
# `case clerk`, verifiedClerkID, and the owner mapping must keep compiling.
if [[ -n "$(build_setting CLERK_PUBLISHABLE_KEY)" || -n "$(build_setting FIRST_PARTY_IOS_AUTH_ENABLED)" ]]; then
  echo "A retired auth build setting returned"
  exit 1
fi
IOS_ROOT="ios/MediaTools" ruby <<'RUBY'
root = ENV.fetch("IOS_ROOT")
sources = Dir.glob(File.join(root, "**", "*.swift"))
offenders = sources.filter do |path|
  File.read(path, encoding: "UTF-8").match?(/^\s*import\s+Clerk|\bClerk\.shared\b|\bAuthView\b|\bClerkKit\b/)
end
abort "Clerk SDK use returned: #{offenders.join(', ')}" unless offenders.empty?

project = File.read(File.join(root, "MediaTools.xcodeproj", "project.pbxproj"), encoding: "UTF-8")
abort "A Clerk package reference returned to the Xcode project" if project.match?(/clerk-ios|ClerkKit|CLERK_PUBLISHABLE_KEY|FIRST_PARTY_IOS_AUTH_ENABLED/i)

resolved = Dir.glob(File.join(root, "**", "Package.resolved"))
abort "A Clerk package pin returned: #{resolved.join(', ')}" if resolved.any? { |path| File.read(path).match?(/clerk/i) }

copy = Dir.glob("ios/app-store/en-US/*.txt")
offending_copy = copy.filter { |path| File.read(path, encoding: "UTF-8").match?(/clerk|sign in with apple/i) }
abort "Store copy still mentions a removed sign-in: #{offending_copy.join(', ')}" unless offending_copy.empty?

%w[signup/verify password/forgot password/reset].each do |route|
  service = File.read(File.join(root, "MediaTools", "Services", "FirstPartyAuthService.swift"), encoding: "UTF-8")
  abort "Sign-in no longer covers /auth/#{route}" unless service.include?("/auth/#{route}")
end
RUBY

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

if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$entitlements_path" >/dev/null 2>&1; then
  echo "The Sign in with Apple entitlement returned; the app offers no third-party sign-in"
  exit 1
fi
# The capture key is shared through the App Group, which iOS also treats as a
# Keychain access group. A keychain-access-groups entitlement would change the
# default group for new items, and the device session must stay out of the
# group the extension can read.
for checked_entitlements in "$entitlements_path" "$share_entitlements_path"; do
  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$checked_entitlements" >/dev/null 2>&1; then
    echo "$checked_entitlements must not declare keychain-access-groups; the device session would become shareable"
    exit 1
  fi
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$checked_entitlements")" == "$app_group" ]] || {
    echo "$checked_entitlements is missing the shared App Group"
    exit 1
  }
done
passkey_domain="webcredentials:media.shimizu-technology.com"
configured_passkey_domain="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.associated-domains:0' "$entitlements_path")"
[[ "$configured_passkey_domain" == "$passkey_domain" ]] || { echo "Unexpected passkey associated domain: $configured_passkey_domain"; exit 1; }

encryption_exempt="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info_plist")"
microphone_copy="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist")"
background_mode="$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' "$info_plist")"
[[ "$encryption_exempt" == "false" ]] || { echo "ITSAppUsesNonExemptEncryption must be false"; exit 1; }
[[ -n "$microphone_copy" ]] || { echo "Microphone usage description is empty"; exit 1; }
[[ "$background_mode" == "audio" ]] || { echo "The recording app must declare the audio background mode"; exit 1; }

plutil -lint "$info_plist" "$privacy_manifest" "ios/MediaTools/ShareExtension/PrivacyInfo.xcprivacy" "$entitlements_path" "$share_entitlements_path" "$export_options_path" >/dev/null

for retired_key in CLERK_PUBLISHABLE_KEY FIRST_PARTY_IOS_AUTH_ENABLED; do
  if /usr/libexec/PlistBuddy -c "Print :$retired_key" "$info_plist" >/dev/null 2>&1; then
    echo "Info.plist still declares $retired_key"
    exit 1
  fi
done

[[ "$(plutil -extract destination raw "$export_options_path")" == "export" ]] || { echo "Export options must create a local artifact for preflight"; exit 1; }
[[ "$(plutil -extract manageAppVersionAndBuildNumber raw "$export_options_path")" == "false" ]] || { echo "Export options must preserve the reviewed build number"; exit 1; }
[[ "$(plutil -extract method raw "$export_options_path")" == "app-store-connect" ]] || { echo "Export options must target App Store Connect"; exit 1; }
[[ "$(plutil -extract signingStyle raw "$export_options_path")" == "automatic" ]] || { echo "Export options must use automatic signing"; exit 1; }
[[ "$(plutil -extract teamID raw "$export_options_path")" == "$team_id" ]] || { echo "Export options use the wrong Apple team"; exit 1; }

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
  [[ -f "$app_path/PlugIns/ShareExtension.appex/PrivacyInfo.xcprivacy" ]] || { echo "Share Extension is missing PrivacyInfo.xcprivacy"; exit 1; }

  preflight_tmp="$(mktemp -d)"
  trap 'rm -rf "$preflight_tmp"' EXIT
  codesign -d --entitlements :- "$app_path" >"$preflight_tmp/app-entitlements.plist" 2>/dev/null
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$preflight_tmp/app-entitlements.plist" >/dev/null 2>&1; then
    echo "Signed archive still has Sign in with Apple"
    exit 1
  fi
  if [[ -d "$app_path/Frameworks/ClerkKit.framework" ]] || grep -rlq "welcomed-earwig-86" "$app_info" 2>/dev/null; then
    echo "Archive still embeds Clerk"
    exit 1
  fi
  archived_passkey_domain="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.associated-domains:0' "$preflight_tmp/app-entitlements.plist")"
  [[ "$archived_passkey_domain" == "$passkey_domain" ]] || { echo "Signed archive is missing the passkey associated domain"; exit 1; }
  archived_app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$preflight_tmp/app-entitlements.plist")"
  [[ "$archived_app_group" == "$app_group" ]] || { echo "Signed archive is missing the share App Group"; exit 1; }

  share_extension_path="$app_path/PlugIns/ShareExtension.appex"
  [[ -d "$share_extension_path" ]] || { echo "Archive is missing ShareExtension.appex"; exit 1; }
  [[ "$(plutil -extract CFBundleVersion raw "$share_extension_path/Info.plist")" == "$build_number" ]] || { echo "Share Extension build number does not match"; exit 1; }
  codesign -d --entitlements :- "$share_extension_path" >"$preflight_tmp/share-entitlements.plist" 2>/dev/null
  archived_share_id="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$preflight_tmp/share-entitlements.plist")"
  archived_share_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$preflight_tmp/share-entitlements.plist")"
  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$preflight_tmp/share-entitlements.plist" >/dev/null 2>&1 \
    && [[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$preflight_tmp/share-entitlements.plist")" == *"$bundle_id"* ]] \
    && [[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$preflight_tmp/share-entitlements.plist")" != *"$bundle_id.ShareExtension"* ]]; then
    echo "Share Extension could read the app's Keychain group"
    exit 1
  fi
  [[ "$archived_share_id" == "$team_id.$bundle_id.ShareExtension" ]] || { echo "Share Extension signed identifier does not match"; exit 1; }
  [[ "$archived_share_group" == "$archived_app_group" ]] || { echo "Share Extension App Group does not match the app"; exit 1; }

  if [[ -f "$app_path/embedded.mobileprovision" ]]; then
    security cms -D -i "$app_path/embedded.mobileprovision" >"$preflight_tmp/profile.plist"
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$preflight_tmp/profile.plist")"
    [[ "$profile_app_id" == "$team_id.$bundle_id" ]] || { echo "Provisioning profile app identifier does not match: $profile_app_id"; exit 1; }
    profile_passkey_domains="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.associated-domains' "$preflight_tmp/profile.plist")"
    if [[ "$profile_passkey_domains" != "$passkey_domain" && "$profile_passkey_domains" != "*" && "$profile_passkey_domains" != *"$passkey_domain"* ]]; then
      echo "Provisioning profile does not allow the passkey associated domain"
      exit 1
    fi
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
  exported_passkey_domain="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:com.apple.developer.associated-domains:0" "$distribution_summary")"
  exported_certificate="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:certificate:type" "$distribution_summary")"
  embedded_indexes="$(plutil -convert json -o - "$distribution_summary" | ruby -rjson -e '
    binaries = JSON.parse(STDIN.read).fetch("MediaTools.ipa").fetch(0).fetch("embeddedBinaries")
    widget = binaries.each_index.select { |index| binaries[index]["name"] == "MediaToolsWidget.appex" }
    share = binaries.each_index.select { |index| binaries[index]["name"] == "ShareExtension.appex" }
    abort "Expected one widget and one Share Extension in export" unless widget.length == 1 && share.length == 1
    puts "#{widget.first} #{share.first}"
  ')"
  read -r widget_index share_index <<< "$embedded_indexes"
  widget_build="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${widget_index}:buildNumber" "$distribution_summary")"
  widget_id="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${widget_index}:entitlements:application-identifier" "$distribution_summary")"
  widget_get_task_allow="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${widget_index}:entitlements:get-task-allow" "$distribution_summary")"
  exported_app_group="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:com.apple.security.application-groups:0" "$distribution_summary")"
  share_build="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${share_index}:buildNumber" "$distribution_summary")"
  share_id="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${share_index}:entitlements:application-identifier" "$distribution_summary")"
  share_group="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${share_index}:entitlements:com.apple.security.application-groups:0" "$distribution_summary")"
  share_get_task_allow="$(/usr/libexec/PlistBuddy -c "Print ${summary_root}:embeddedBinaries:${share_index}:entitlements:get-task-allow" "$distribution_summary")"

  [[ "$exported_build" == "$build_number" ]] || { echo "Exported build number does not match"; exit 1; }
  [[ "$exported_version" == "$marketing_version" ]] || { echo "Exported marketing version does not match"; exit 1; }
  [[ "$exported_app_id" == "$team_id.$bundle_id" ]] || { echo "Exported application identifier does not match"; exit 1; }
  [[ "$exported_get_task_allow" == "false" ]] || { echo "App Store export is debuggable"; exit 1; }
  if /usr/libexec/PlistBuddy -c "Print ${summary_root}:entitlements:com.apple.developer.applesignin" "$distribution_summary" >/dev/null 2>&1; then
    echo "App Store export still has Sign in with Apple"
    exit 1
  fi
  [[ "$exported_passkey_domain" == "$passkey_domain" ]] || { echo "App Store export is missing the passkey associated domain"; exit 1; }
  [[ "$exported_certificate" == *"Apple Distribution"* ]] || { echo "App Store export is not distribution-signed: $exported_certificate"; exit 1; }
  [[ "$widget_build" == "$build_number" ]] || { echo "Widget build number does not match the app"; exit 1; }
  [[ "$widget_id" == "$team_id.$bundle_id.Widget" ]] || { echo "Exported widget identity does not match"; exit 1; }
  [[ "$widget_get_task_allow" == "false" ]] || { echo "Exported widget is debuggable"; exit 1; }
  [[ "$exported_app_group" == "$app_group" ]] || { echo "Exported app is missing the share App Group"; exit 1; }
  [[ "$share_build" == "$build_number" ]] || { echo "Exported Share Extension has the wrong build number"; exit 1; }
  [[ "$share_id" == "$team_id.$bundle_id.ShareExtension" && "$share_group" == "$exported_app_group" ]] || { echo "Exported Share Extension identity or App Group does not match"; exit 1; }
  [[ "$share_get_task_allow" == "false" ]] || { echo "Exported Share Extension is debuggable"; exit 1; }
fi

echo "iOS release preflight passed for Media Tools $marketing_version ($build_number) with Xcode $xcode_version / iOS SDK $sdk_version"
