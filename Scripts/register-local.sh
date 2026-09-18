#!/bin/bash
# Register these local build products in place; never move or delete packages.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "") check_only=false ;;
  --check-only) check_only=true ;;
  --help|-h)
    echo 'Usage: Scripts/register-local.sh [--check-only]'
    echo 'Checks the helper and audio app signatures, then registers their'
    echo 'existing build paths with Launch Services and PlugInKit for this user.'
    echo 'Does not move/delete installed packages, change permissions, or open apps.'
    exit 0 ;;
  *) echo 'Usage: Scripts/register-local.sh [--check-only]' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo 'Usage: Scripts/register-local.sh [--check-only]' >&2
  exit 2
fi

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pluginkit=/usr/bin/pluginkit
helper="$PWD/build/Cutdown.app"
audio="$PWD/build/AudioPlugin/Build/Products/Debug/CutdownAudio.app"
audio_extension="$audio/Contents/PlugIns/CutdownAudioExtension.appex"

for tool in "$lsregister" "$pluginkit" /usr/bin/codesign /usr/libexec/PlistBuddy; do
  if [[ ! -x "$tool" ]]; then
    printf 'Required macOS tool is missing: %s\n' "$tool" >&2
    exit 1
  fi
done

check_bundle() {
  local path="$1" expected_identifier="$2" actual_identifier
  if [[ ! -d "$path" || ! -f "$path/Contents/Info.plist" ]]; then
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
check_bundle "$helper" local.cutdown.helper
check_bundle "$audio" local.cutdown.audio
check_bundle "$audio_extension" local.cutdown.audio.extension
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
candidate="$PWD/build/Candidate/Cutdown.app"
if [[ -f "$candidate/Contents/Info.plist" ]]; then
  candidate_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
  if [[ "$candidate_identifier" == local.cutdown.helper || "$candidate_identifier" == local.cutdown.helper.candidate ]]; then
    remove_candidate_registration "$lsregister" -u "$candidate"
  fi
fi
# Xcode registers staged Audio Units too. Remove competing standard and isolated
# diagnostic candidates while the host is stopped, then select the installed copy.
# Only our audio bundle identity qualifies; preserve every bundle on disk.
for audio_candidate in "$PWD/build/Candidate/AudioPlugin/CutdownAudio.app" "$PWD"/build/*/Candidate/CutdownAudio.app; do
  if [[ -f "$audio_candidate/Contents/Info.plist" ]]; then
    candidate_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$audio_candidate/Contents/Info.plist")
    if [[ "$candidate_identifier" == local.cutdown.audio ]]; then
      remove_candidate_registration "$pluginkit" -r "$audio_candidate/Contents/PlugIns/CutdownAudioExtension.appex"
      remove_candidate_registration "$lsregister" -u "$audio_candidate"
    fi
  fi
done
"$lsregister" -f "$helper"
"$lsregister" -f "$audio"
"$pluginkit" -a "$audio_extension"
# Adding can return before discovery catches up. Do not report success merely
# because the command exited zero: require the installed path in the registry.
registration=''
for attempt in 1 2 3 4 5; do
  registration=$("$pluginkit" -m -A -D -v -i local.cutdown.audio.extension) || exit 1
  if [[ "$registration" == *"$audio_extension"* ]]; then break; fi
  if [[ "$attempt" != 5 ]]; then /bin/sleep 1; fi
done
if [[ "$registration" != *"$audio_extension"* ]]; then
  echo 'Cutdown was not found at the installed path after registration. Keep Final Cut closed and retry Scripts/register-local.sh.' >&2
  exit 1
fi
echo 'Registered the Cutdown helper and Audio Unit from their existing build paths.'
echo 'Keep these build products in place while testing them in Final Cut Pro.'
printf '%s\n' "$registration"
