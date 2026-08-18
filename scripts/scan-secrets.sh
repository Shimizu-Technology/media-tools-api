#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gitleaks_version="8.30.1"

prepare_gitleaks() {
  local os arch archive expected actual

  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *)
      echo "Secret scan supports macOS and Linux hosts." >&2
      return 1
      ;;
  esac

  case "$(uname -m)" in
    arm64 | aarch64) arch="arm64" ;;
    x86_64 | amd64) arch="x64" ;;
    *)
      echo "Secret scan does not support architecture $(uname -m)." >&2
      return 1
      ;;
  esac

  archive="gitleaks_${gitleaks_version}_${os}_${arch}.tar.gz"
  case "${os}_${arch}" in
    darwin_arm64) expected="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    darwin_x64) expected="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
    linux_arm64) expected="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
    linux_x64) expected="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
  esac
  scanner_dir="$(mktemp -d "${TMPDIR:-/tmp}/media-tools-gitleaks.XXXXXX")"
  chmod 700 "$scanner_dir"

  curl --fail --silent --show-error --location --retry 3 \
    --output "$scanner_dir/$archive" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/$archive"

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$scanner_dir/$archive" | awk '{ print $1 }')"
  else
    actual="$(shasum -a 256 "$scanner_dir/$archive" | awk '{ print $1 }')"
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum verification failed for $archive." >&2
    return 1
  fi

  tar -xzf "$scanner_dir/$archive" -C "$scanner_dir" gitleaks
  chmod 500 "$scanner_dir/gitleaks"
  gitleaks_binary="$scanner_dir/gitleaks"
}

scanner_dir=""
snapshot_dir=""
cleanup() {
  [[ -z "$scanner_dir" ]] || rm -rf -- "$scanner_dir"
  [[ -z "$snapshot_dir" ]] || rm -rf -- "$snapshot_dir"
}
trap cleanup EXIT

echo "Preparing an isolated, verified Gitleaks v$gitleaks_version"
prepare_gitleaks

cd "$repo_root"
echo "Scanning committed history for credentials"
"$gitleaks_binary" git \
  --config .gitleaks.toml \
  --redact=100 \
  --no-banner \
  --log-opts="${GITLEAKS_LOG_OPTS:---all}"

echo "Scanning the current working tree for credentials"
snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/media-tools-worktree.XXXXXX")"
while IFS= read -r -d '' path; do
  [[ -f "$path" ]] || continue
  mkdir -p "$snapshot_dir/$(dirname "$path")"
  cp -- "$path" "$snapshot_dir/$path"
done < <(git ls-files --cached --others --exclude-standard -z)

"$gitleaks_binary" dir \
  --config .gitleaks.toml \
  --redact=100 \
  --no-banner \
  "$snapshot_dir"
