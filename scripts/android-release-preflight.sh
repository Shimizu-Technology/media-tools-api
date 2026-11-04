#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

search_file() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

require_source() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! search_file "$pattern" "$file"; then
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

if search_file 'READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|READ_MEDIA_(AUDIO|IMAGES|VIDEO)' \
  android/app/src/main/AndroidManifest.xml; then
  echo "Android must use system document pickers instead of broad media or storage permission"
  exit 1
fi

# Media Tools owns Android sign-in. Fail if a known third-party sign-in SDK returns, so
# the Play data safety answers stay true.
if grep -Eiq 'clerk|auth0|firebase-auth|play-services-auth|appauth|msal' android/app/build.gradle.kts android/gradle/libs.versions.toml; then
  echo "Android must not depend on a third-party sign-in SDK"
  exit 1
fi
require_source '^[[:space:]]*buildConfigField\("String", "API_BASE_URL", "\\"https://media-tools-api\.onrender\.com/api/v1\\""\)' android/app/build.gradle.kts \
  "Android API_BASE_URL must be https://media-tools-api.onrender.com/api/v1"
if search_file 'FIRST_PARTY_ANDROID_AUTH' android/app/build.gradle.kts; then
  echo "Android first-party sign-in must be on in every build, not behind a flag"
  exit 1
fi

for url in privacy terms support delete-account; do
  require_source "https://media\.shimizu-technology\.com/$url" \
    android/app/src/main/kotlin/com/shimizutechnology/mediatools/AppLinks.kt \
    "Android is missing its public $url URL"
done

if [[ "${1:-}" != "--release" ]]; then
  echo "Android source preflight passed"
  exit 0
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
