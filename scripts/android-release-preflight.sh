#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_source() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! rg -q "$pattern" "$file"; then
    echo "$message"
    exit 1
  fi
}

require_source 'applicationId = "com\.shimizutechnology\.mediatools"' android/app/build.gradle.kts \
  "Android application ID must remain com.shimizutechnology.mediatools"
require_source 'targetSdk = 36' android/app/build.gradle.kts \
  "Android must target API 36 or higher for the August 2026 Play requirement"
require_source 'compileSdk = 36' android/app/build.gradle.kts \
  "Android compileSdk must match the tested API 36 platform"
require_source 'android\.permission\.INTERNET' android/app/src/main/AndroidManifest.xml \
  "Android must declare internet access"

if rg -q 'READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|READ_MEDIA_(AUDIO|IMAGES|VIDEO)' \
  android/app/src/main/AndroidManifest.xml; then
  echo "Android must use system document pickers instead of broad media or storage permission"
  exit 1
fi

for url in privacy terms support delete-account; do
  require_source "https://media-tools-gu\.netlify\.app/$url" \
    android/app/src/main/kotlin/com/shimizutechnology/mediatools/AppLinks.kt \
    "Android is missing its public $url URL"
done

if [[ "${1:-}" != "--release" ]]; then
  echo "Android source preflight passed"
  exit 0
fi

publishable_key="${MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY:-}"
if [[ "$publishable_key" != pk_live_* ]]; then
  echo "Play release is blocked until MEDIA_TOOLS_CLERK_PUBLISHABLE_KEY uses the Clerk production instance"
  exit 1
fi

required_release_variables=(
  MEDIA_TOOLS_ANDROID_KEYSTORE_PATH
  MEDIA_TOOLS_ANDROID_KEYSTORE_PASSWORD
  MEDIA_TOOLS_ANDROID_KEY_ALIAS
  MEDIA_TOOLS_ANDROID_KEY_PASSWORD
)
for variable_name in "${required_release_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Play release is missing $variable_name"
    exit 1
  fi
done

if [[ ! -f "$MEDIA_TOOLS_ANDROID_KEYSTORE_PATH" ]]; then
  echo "Android release keystore was not found at the configured path"
  exit 1
fi

echo "Android release configuration preflight passed"
