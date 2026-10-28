#!/bin/bash
# Package the focus-required prototype used through the existing Final Cut AU.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: Scripts/build-quiet-share-prototype.sh'
  echo 'Builds a signed Debug prototype operated from the existing Final Cut effect controls.'
  echo 'Output: build/QuietSharePrototype/App/Silent Snip.app and dist/Silent Snip Prototype.zip'
  echo 'Does not install, register, launch, or change the normal app/ZIP.'
  exit 0
fi
[[ $# == 0 ]] || { echo 'Unknown argument. Use --help.' >&2; exit 2; }
destination="$PWD/build/QuietSharePrototype/App/Silent Snip.app"
check_stopped() {
  local pattern result
  pattern=$(printf '%s' "$destination/Contents/" | /usr/bin/sed 's/[][\.^$*+?(){}|]/\\&/g')
  if /usr/bin/pgrep -f "^${pattern}" >/dev/null; then
    echo 'Quit this prototype before replacing its output.' >&2; exit 1
  else result=$?; [[ "$result" == 1 ]] || { echo 'Cannot inspect running prototypes.' >&2; exit 1; }; fi
}
check_stopped
Scripts/build-app.sh --stage --debug
mkdir -p build/QuietSharePrototype/App dist
work=$(mktemp -d "$PWD/build/QuietSharePrototype/.package.XXXXXX")
cleanup() { if [[ ! -e "$work/Previous.app" ]]; then rm -rf "$work"; fi; }
trap cleanup EXIT
app="$work/Silent Snip.app"
/usr/bin/ditto "$PWD/build/Candidate/App/Silent Snip.app" "$app"
cp Config/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SilentSnipQuietSharePrototype bool true' "$app/Contents/Info.plist"
extension="$app/Contents/PlugIns/SilentSnipAudio.appex"
/usr/libexec/PlistBuddy -c 'Set :SilentSnipContainingApp:enabled true' "$extension/Contents/Info.plist"
codesign --force --preserve-metadata=entitlements --sign "${SILENT_SNIP_SIGNING_IDENTITY:--}" "$extension"
codesign --force --sign "${SILENT_SNIP_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/Silent Snip Prototype.zip"
/usr/bin/unzip -tq "$work/Silent Snip Prototype.zip"
check_stopped
[[ ! -L "$destination" ]] || { echo 'Prototype output must not be a symbolic link.' >&2; exit 1; }
if [[ -e "$destination" ]]; then mv "$destination" "$work/Previous.app"; fi
if ! mv "$app" "$destination"; then
  if [[ -e "$work/Previous.app" ]]; then mv "$work/Previous.app" "$destination"; fi
  exit 1
fi
if ! mv "$work/Silent Snip Prototype.zip" "$PWD/dist/Silent Snip Prototype.zip"; then
  mv "$destination" "$app"
  if [[ -e "$work/Previous.app" ]]; then mv "$work/Previous.app" "$destination"; fi
  exit 1
fi
if [[ -e "$work/Previous.app" ]]; then rm -rf "$work/Previous.app"; fi
printf 'Prototype: %s\nZIP: %s\n' "$destination" "$PWD/dist/Silent Snip Prototype.zip"
