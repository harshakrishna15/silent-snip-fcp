#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=false
configuration=debug
while [[ "${1:-}" == --stage || "${1:-}" == --release ]]; do
  if [[ "$1" == --stage ]]; then stage=true; else configuration=release; fi
  shift
done
check_helper_stopped() {
  # Staged builds have a separate identity and never replace the live helper.
  if [[ "$stage" == true ]]; then return; fi
  if /usr/bin/pgrep -x Cutdown >/dev/null; then
    echo 'Quit Cutdown before replacing its installed helper, or build with --stage. The running helper would otherwise continue using the old code.' >&2
    exit 1
  else
    local status=$?
    if [[ "$status" != 1 ]]; then
      echo 'Cannot verify whether Cutdown is running. Build with --stage, or retry with process-list access; the installed helper was not replaced.' >&2
      exit 1
    fi
  fi
}
check_helper_stopped
mkdir -p build/module-cache build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache"
swift build --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache -c "$configuration" --product Cutdown "$@"
binary_dir=$(swift build --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache -c "$configuration" --show-bin-path "$@")
# Build and verify a complete candidate before replacing the registered bundle.
# Personal builds default to ad hoc. An existing identity can be supplied without
# creating certificates or changing keychain/accessibility permissions.
signing_identity="${CUTDOWN_SIGNING_IDENTITY:--}"
installed_app="$PWD/build/Cutdown.app"
if [[ "$stage" == true ]]; then
  mkdir -p build/Candidate
  installed_app="$PWD/build/Candidate/Cutdown.app"
fi
staging_dir=$(mktemp -d "$PWD/build/helper-stage.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/Cutdown.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Cutdown" "$app/Contents/MacOS/Cutdown"
cp Config/Info.plist "$app/Contents/Info.plist"
cp Config/Cutdown.sdef "$app/Contents/Resources/Cutdown.sdef"
expected_identifier=local.cutdown.helper
if [[ "$stage" == true ]]; then
  # Launch Services can discover staged apps without explicit registration.
  # Candidates must not compete for the installed helper's URL/share routes.
  expected_identifier=local.cutdown.helper.candidate
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $expected_identifier" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Cutdown Candidate' "$app/Contents/Info.plist"
  for key in CFBundleURLTypes CFBundleDocumentTypes com.apple.proapps.MediaAssetProtocol; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$app/Contents/Info.plist"
  done
fi
codesign --force --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$identifier" == "$expected_identifier" && -x "$app/Contents/MacOS/Cutdown" ]]
# A helper may have launched while Swift was building. Check again immediately
# before replacing the installed bundle; never terminate an active job here.
check_helper_stopped
if [[ -e "$installed_app" ]]; then mv "$installed_app" "$staging_dir/Previous.app"; fi
if ! mv "$app" "$installed_app"; then
  if [[ -e "$staging_dir/Previous.app" ]]; then mv "$staging_dir/Previous.app" "$installed_app"; fi
  exit 1
fi
app="$installed_app"
printf '%s\n' "$app"
