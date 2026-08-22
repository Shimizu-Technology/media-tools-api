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

if [[ -x android/gradlew ]]; then
  echo "Running Android source preflight"
  ./scripts/android-release-preflight.sh

  android_sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$android_sdk_root" && "$(uname -s)" == "Darwin" && -d "$HOME/Library/Android/sdk" ]]; then
    android_sdk_root="$HOME/Library/Android/sdk"
  fi
  if [[ -n "$android_sdk_root" && -d "$android_sdk_root" ]]; then
    echo "Running Android lint, tests, and debug build"
    (
      cd android
      ANDROID_HOME="$android_sdk_root" CI=true ./gradlew --no-daemon lint testDebugUnitTest assembleDebug
    )
  else
    echo "Skipping Android SDK checks because no Android SDK is configured"
  fi
fi

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then
  echo "Running iOS build and tests"
  ./scripts/ios-release-preflight.sh

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
