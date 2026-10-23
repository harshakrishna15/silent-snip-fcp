#!/bin/bash
# Register these local build products in place; never move or delete packages.
set -euo pipefail
cd "$(dirname "$0")/.."

check_only=false
app_path=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) check_only=true; shift ;;
    --app)
      [[ $# -ge 2 && "$2" == /* ]] || { echo '--app requires an absolute app path.' >&2; exit 2; }
      app_path="$2"; shift 2 ;;
    --help|-h)
      echo 'Usage: Scripts/register-local.sh [--check-only] [--app /absolute/Silent Snip.app]'
      echo 'Verifies and registers the combined app, or legacy developer builds if absent.'
      echo 'No app copies, launches, deletions, or permission changes are performed.'
      exit 0 ;;
    *) echo 'Usage: Scripts/register-local.sh [--check-only] [--app /absolute/Silent Snip.app]' >&2; exit 2 ;;
  esac
done

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pluginkit=/usr/bin/pluginkit
combined=false
if [[ -z "$app_path" && -d "$PWD/build/App/Silent Snip.app" ]]; then app_path="$PWD/build/App/Silent Snip.app"; fi
if [[ -n "$app_path" ]]; then
  combined=true
  helper="$app_path"
  audio="$app_path"
else
  helper="$PWD/build/SilentSnipHelper.app"
  audio="$PWD/build/AudioPlugin/Build/Products/Debug/CutdownAudio.app"
fi
audio_extension="$audio/Contents/PlugIns/SilentSnipAudio.appex"

for tool in "$lsregister" "$pluginkit" /usr/bin/codesign /usr/libexec/PlistBuddy; do
  if [[ ! -x "$tool" ]]; then
    printf 'Required macOS tool is missing: %s\n' "$tool" >&2
    exit 1
  fi
done

check_bundle() {
  local path="$1" expected_identifier="$2" actual_identifier
  if [[ ! -d "$path" || -L "$path" || -L "$path/Contents" || ! -f "$path/Contents/Info.plist" ]]; then
    printf 'Build product is missing: %s\nRun build-helper.sh and build-audio-plugin.sh first.\n' "$path" >&2
    exit 1
  fi
  actual_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist")
  if [[ "$actual_identifier" != "$expected_identifier" ]]; then
    printf 'Unexpected bundle identifier at %s: %s\n' "$path" "$actual_identifier" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict "$path"
}

# Complete every check before modifying either macOS registration database.
if [[ "$combined" == true ]]; then
  check_bundle "$helper" local.silentsnip.app
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper/Contents/Info.plist")
  [[ "$executable" == SilentSnip && -x "$helper/Contents/MacOS/SilentSnip" && -f "$helper/Contents/Resources/SilentSnip.sdef" ]] || { echo 'The combined app is missing its helper or Share definitions.' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$helper/Contents/Info.plist" >/dev/null || { echo 'This is an inert candidate, not a complete app.' >&2; exit 1; }
else
  check_bundle "$helper" local.silentsnip.helper
  check_bundle "$audio" local.silentsnip.app
fi
check_bundle "$audio_extension" local.silentsnip.app.audio
extension_point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$audio_extension/Contents/Info.plist")
factory_class=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$audio_extension/Contents/Info.plist")
if [[ "$extension_point" != com.apple.AudioUnit-UI || "$factory_class" != CutdownAudioUnitFactory ]]; then
  echo 'The audio build is missing the current custom effect window. Rebuild with build-audio-plugin.sh before registering.' >&2
  exit 1
fi
if [[ "$check_only" == true ]]; then
  echo 'All local build products and signatures passed. No registration changed.'
  exit 0
fi

# Re-registering an active extension causes PlugInKit to terminate its process.
# The host reports this as an unresponsive plug-in and disables its instances.
if /usr/bin/pgrep -x 'Final Cut Pro' >/dev/null; then
  echo 'Quit Final Cut Pro before registering the audio plug-in. Use --check-only for validation while Final Cut is open.' >&2
  exit 1
else
  status=$?
  if [[ "$status" != 1 ]]; then
    echo 'Cannot verify whether Final Cut is running. Retry with process-list access; no registration changed.' >&2
    exit 1
  fi
fi

# Older staged builds advertised the live URL and Share handlers. Remove their
# cached registration before making the installed helper the current handler.
# Cleanup can report an already-absent registration. It must never prevent
# the installed app from being registered after another candidate was removed.
remove_candidate_registration() {
  if ! "$@"; then
    printf 'Candidate cleanup did not complete; continuing to register the installed app: %s\n' "$*" >&2
  fi
}
candidate="$PWD/build/Candidate/SilentSnipHelper.app"
if [[ -f "$candidate/Contents/Info.plist" ]]; then
  candidate_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
  if [[ "$candidate_identifier" == local.silentsnip.helper || "$candidate_identifier" == local.silentsnip.helper.candidate ]]; then
    remove_candidate_registration "$lsregister" -u "$candidate"
  fi
fi
# Xcode registers staged Audio Units too. Remove competing standard and isolated
# diagnostic candidates while the host is stopped, then select the installed copy.
# Only our audio bundle identity qualifies; preserve every bundle on disk.
for audio_candidate in "$PWD/build/Candidate/App/Silent Snip.app" "$PWD/build/Candidate/AudioPlugin/CutdownAudio.app" "$PWD"/build/*/Candidate/CutdownAudio.app; do
  if [[ -f "$audio_candidate/Contents/Info.plist" ]]; then
    candidate_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$audio_candidate/Contents/Info.plist")
    if [[ "$candidate_identifier" == local.silentsnip.app ]]; then
      remove_candidate_registration "$pluginkit" -r "$audio_candidate/Contents/PlugIns/SilentSnipAudio.appex"
      remove_candidate_registration "$lsregister" -u "$audio_candidate"
    fi
  fi
done
"$lsregister" -f "$helper"
if [[ "$audio" != "$helper" ]]; then "$lsregister" -f "$audio"; fi
"$pluginkit" -a "$audio_extension"
# Adding can return before discovery catches up. Do not report success merely
# because the command exited zero: require the installed path in the registry.
registration=''
for attempt in 1 2 3 4 5; do
  registration=$("$pluginkit" -m -A -D -v -i local.silentsnip.app.audio) || exit 1
  if [[ "$registration" == *"$audio_extension"* ]]; then break; fi
  if [[ "$attempt" != 5 ]]; then /bin/sleep 1; fi
done
if [[ "$registration" != *"$audio_extension"* ]]; then
  echo 'Silent Snip was not found at the installed path after registration. Keep Final Cut closed and retry Scripts/register-local.sh.' >&2
  exit 1
fi
echo 'Registered the Silent Snip app and Audio Unit from their existing paths.'
echo 'Keep these build products in place while testing them in Final Cut Pro.'
printf '%s\n' "$registration"
