#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Running credential scan"
./scripts/scan-secrets.sh

echo "Running backend checks"
unformatted="$(find cmd internal -name '*.go' -type f -print0 | xargs -0 gofmt -l)"
if [[ -n "$unformatted" ]]; then
  echo "Go files require formatting:"
  echo "$unformatted"
  exit 1
fi
go list ./... | grep -v '/frontend/node_modules/' | xargs go vet
go list ./... | grep -v '/frontend/node_modules/' | xargs go test -race

echo "Running frontend checks"
(
  cd frontend
  npm ci
  npm run lint
  npm run build
  npm run audit:prod
)

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then
  echo "Running iOS build and tests"

  entitlements_path="ios/MediaTools/MediaTools/MediaTools.entitlements"
  if [[ ! -f "$entitlements_path" ]]; then
    echo "Missing iOS entitlements file: $entitlements_path"
    exit 1
  fi

  if ! apple_sign_in_mode="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$entitlements_path" 2>/dev/null)"; then
    echo "Sign in with Apple entitlement is missing"
    exit 1
  fi
  if [[ "$apple_sign_in_mode" != "Default" ]]; then
    echo "Sign in with Apple entitlement is missing or invalid: $apple_sign_in_mode"
    exit 1
  fi

  configured_entitlements="$(xcodebuild \
    -project ios/MediaTools/MediaTools.xcodeproj \
    -scheme MediaTools \
    -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/^[[:space:]]*CODE_SIGN_ENTITLEMENTS = / { print $2; exit }')"
  if [[ "$configured_entitlements" != "MediaTools/MediaTools.entitlements" ]]; then
    echo "Unexpected iOS entitlements build setting: $configured_entitlements"
    exit 1
  fi

  simulator_id="${IOS_SIMULATOR_ID:-$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    # Reuse a booted simulator when possible. Starting a second CoreSimulator
    # runtime while another is active can leave Xcode waiting indefinitely for
    # a test runner to materialize. CI can still pin a device explicitly with
    # IOS_SIMULATOR_ID.
    preferred = devices.find do |device|
      device["state"] == "Booted" && device["name"].to_s.start_with?("iPhone")
    end
    preferred ||= devices.find { |device| device["name"] == "iPhone 16 Pro" }
    selected = preferred || devices.find { |device| device["name"].to_s.start_with?("iPhone") }
    abort "No available iPhone simulator found" unless selected
    puts selected.fetch("udid")
  ')}"

  derived_data="${TMPDIR:-/tmp}/media-tools-gate-derived-data"
  result_bundle="${TMPDIR:-/tmp}/media-tools-gate.xcresult"
  rm -rf "$derived_data" "$result_bundle"

  xcrun simctl boot "$simulator_id" 2>/dev/null || true
  xcrun simctl bootstatus "$simulator_id" -b

  xcodebuild \
    -project ios/MediaTools/MediaTools.xcodeproj \
    -scheme MediaTools \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -only-testing:MediaToolsTests \
    -parallel-testing-enabled NO \
    test \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

  app_path="$derived_data/Build/Products/Debug-iphonesimulator/MediaTools.app"
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")"
  if [[ "$bundle_id" != "com.ShimizuTechnology.MediaTools" ]]; then
    echo "Unexpected iOS bundle identifier: $bundle_id"
    exit 1
  fi

  xcrun simctl install "$simulator_id" "$app_path"
  xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"
  xcrun simctl terminate "$simulator_id" "$bundle_id"
else
  echo "Skipping iOS checks because this host does not provide Xcode"
fi

echo "Gate passed"
