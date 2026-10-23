#!/bin/bash
# Assemble one containing app. Never install into Applications or grant access.
set -euo pipefail
cd "$(dirname "$0")/.."
debug=false
stage=false
reuse=false
for argument in "$@"; do
  case "$argument" in
    --debug) debug=true ;;
    --stage) stage=true ;;
    --reuse-components) reuse=true ;;
    --help|-h)
      echo 'Usage: Scripts/build-app.sh [--debug] [--stage] [--reuse-components]'
      echo 'Builds build/App/Silent Snip.app and dist/Silent Snip.zip (Release by default).'
      echo '--stage builds an inert candidate without changing the published app or ZIP.'
      echo '--reuse-components packages the existing staged helper and audio builds.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
output="$PWD/build/App"
if [[ "$stage" == true ]]; then output="$PWD/build/Candidate/App"; fi
destination="$output/Silent Snip.app"
check_stopped() {
  local result
  if [[ "$stage" == false ]]; then
    for name in 'Final Cut Pro' SilentSnip Cutdown; do
      if /usr/bin/pgrep -x "$name" >/dev/null; then
        echo 'Quit Final Cut Pro and Silent Snip before publishing the app, or use --stage.' >&2; exit 1
      else result=$?; [[ "$result" == 1 ]] || { echo 'Cannot inspect running apps; no bundle was replaced.' >&2; exit 1; }; fi
    done
  fi
  # Protect either output even when a staged candidate was launched manually.
  local pattern
  pattern=$(printf '%s' "$destination/Contents/" | /usr/bin/sed 's/[][\.^$*+?(){}|]/\\&/g')
  if /usr/bin/pgrep -f "^${pattern}" >/dev/null; then
    echo 'This output app or its extension is running. Quit it before rebuilding.' >&2; exit 1
  else result=$?; [[ "$result" == 1 ]] || { echo 'Cannot inspect the output app; no bundle was replaced.' >&2; exit 1; }; fi
}
check_stopped
[[ ! -L "$output" && ! -L "$destination" ]] || { echo 'The app output must not be a symbolic link.' >&2; exit 1; }
if [[ -e "$destination" ]]; then
  identity=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  [[ "$identity" == local.silentsnip.app || "$identity" == local.cutdown.audio ]] || { echo 'An unrelated app occupies the output path; it was kept.' >&2; exit 1; }
fi
if [[ "$reuse" == false ]]; then
  helper_args=(--stage)
  if [[ "$debug" == false ]]; then helper_args+=(--release); fi
  Scripts/build-helper.sh "${helper_args[@]}"
  audio_args=(--stage)
  if [[ "$debug" == true ]]; then audio_args+=(--debug); fi
  Scripts/build-audio-plugin.sh "${audio_args[@]}"
fi
helper="$PWD/build/Candidate/SilentSnipHelper.app"
extension="$PWD/build/Candidate/AudioPlugin/SilentSnipAudio.appex"
[[ -x "$helper/Contents/MacOS/SilentSnip" && -d "$extension" ]] || { echo 'Staged components are missing. Build without --reuse-components.' >&2; exit 1; }
[[ ! -L "$helper" && ! -L "$extension" ]] || { echo 'Staged components must not be symbolic links.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper/Contents/Info.plist") == local.silentsnip.helper.candidate ]] || { echo 'Unexpected helper identity.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Contents/Info.plist") == local.silentsnip.app.audio ]] || { echo 'Unexpected extension identity.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :SilentSnipContainingApp:bundleIdentifier' "$extension/Contents/Info.plist") == local.silentsnip.app &&
   $(/usr/libexec/PlistBuddy -c 'Print :SilentSnipContainingApp:executable' "$extension/Contents/Info.plist") == SilentSnip &&
   $(/usr/libexec/PlistBuddy -c 'Print :SilentSnipContainingApp:enabled' "$extension/Contents/Info.plist") == true ]] || {
  echo 'The staged extension has no live combined-app contract. Rebuild without --reuse-components.' >&2; exit 1;
}
codesign --verify --deep --strict "$helper"
codesign --verify --deep --strict "$extension"
mkdir -p build "$output"
work=$(mktemp -d "$PWD/build/.single-app.XXXXXX")
cleanup() { if [[ ! -e "$work/Previous.app" ]]; then rm -rf "$work"; fi; }
trap cleanup EXIT
app="$work/Silent Snip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"
cp "$helper/Contents/MacOS/SilentSnip" "$app/Contents/MacOS/SilentSnip"
cp Config/Info.plist "$app/Contents/Info.plist"
cp Config/SilentSnip.sdef "$app/Contents/Resources/SilentSnip.sdef"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.silentsnip.app' "$app/Contents/Info.plist"
if [[ "$stage" == true ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Silent Snip Candidate' "$app/Contents/Info.plist"
  for key in CFBundleURLTypes CFBundleDocumentTypes com.apple.proapps.MediaAssetProtocol; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$app/Contents/Info.plist"
  done
fi
/usr/bin/ditto "$extension" "$app/Contents/PlugIns/SilentSnipAudio.appex"
if [[ "$stage" == true ]]; then
  candidate_extension="$app/Contents/PlugIns/SilentSnipAudio.appex"
  /usr/libexec/PlistBuddy -c 'Set :SilentSnipContainingApp:enabled false' "$candidate_extension/Contents/Info.plist"
  codesign --force --preserve-metadata=entitlements --sign "${CUTDOWN_SIGNING_IDENTITY:--}" "$candidate_extension"
fi
# Do not apply the extension's sandbox entitlements to the containing app.
codesign --force --sign "${CUTDOWN_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$stage" == false ]]; then
  mkdir -p dist
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/Silent Snip.zip"
fi
check_stopped
if [[ -e "$destination" ]]; then mv "$destination" "$work/Previous.app"; fi
if ! mv "$app" "$destination"; then
  if [[ -e "$work/Previous.app" ]]; then mv "$work/Previous.app" "$destination"; fi
  exit 1
fi
if [[ "$stage" == false ]] && ! mv "$work/Silent Snip.zip" "$PWD/dist/Silent Snip.zip"; then
  mv "$destination" "$app"
  if [[ -e "$work/Previous.app" ]]; then mv "$work/Previous.app" "$destination"; fi
  exit 1
fi
if [[ -e "$work/Previous.app" ]]; then rm -rf "$work/Previous.app"; fi
printf 'App: %s\n' "$destination"
if [[ "$stage" == false ]]; then printf 'Archive: %s\n' "$PWD/dist/Silent Snip.zip"; fi
