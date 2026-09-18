#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=false
if [[ "${1:-}" == --stage ]]; then stage=true; shift; fi
check_host_stopped() {
  if [[ "$stage" == true ]]; then return; fi
  if /usr/bin/pgrep -x 'Final Cut Pro' >/dev/null; then
    echo 'Quit Final Cut Pro before replacing its registered audio plug-in, or build with --stage. Replacing a loaded extension can disconnect it.' >&2
    exit 1
  else
    local status=$?
    if [[ "$status" != 1 ]]; then
      echo 'Cannot verify whether Final Cut is running. Build with --stage, or retry with process-list access; registered bundles were not replaced.' >&2
      exit 1
    fi
  fi
}
# Xcode registers the staged copy with the live AU identity. Final Cut may
# launch it until register-local.sh selects the installed copy; never overwrite
# an actually loaded copy.
candidate="$PWD/build/Candidate/AudioPlugin/CutdownAudio.app"
candidate_executable="$candidate/Contents/PlugIns/CutdownAudioExtension.appex/Contents/MacOS/CutdownAudioExtension"
candidate_pattern=$(printf '%s' "$candidate_executable" | /usr/bin/sed 's/[][\.^$*+?(){}|]/\\&/g')
if /usr/bin/pgrep -f "^${candidate_pattern}([[:space:]]|$)" >/dev/null; then
  echo 'Final Cut is using the staged audio plug-in. Quit Final Cut, then rebuild and run register-local.sh to select the installed copy. The loaded candidate was not replaced.' >&2
  exit 1
else
  status=$?
  if [[ "$status" != 1 ]]; then
    echo 'Cannot verify whether the staged audio plug-in is loaded. Retry with process-list access; no bundle was replaced.' >&2
    exit 1
  fi
fi
check_host_stopped
mkdir -p build/AudioPlugin build/module-cache build/Candidate/AudioPlugin
# Always compile into the reusable candidate graph. Xcode must never write into
# the registered bundle while Final Cut could launch during a long compilation.
xcodebuild -project CutdownAudio.xcodeproj -scheme CutdownAudio -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/build/AudioPluginStage" \
    CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
    CODE_SIGN_IDENTITY="${CUTDOWN_SIGNING_IDENTITY:--}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${CUTDOWN_DEVELOPMENT_TEAM:-}" "$@" \
    "CONFIGURATION_BUILD_DIR=$PWD/build/Candidate/AudioPlugin" build
codesign --verify --deep --strict "$candidate"
if [[ "$stage" == true ]]; then
  echo 'Xcode may register this candidate. Before live testing, quit Final Cut, build without --stage, and run Scripts/register-local.sh.' >&2
  printf '%s\n' "$candidate"
  exit 0
fi
installed="$PWD/build/AudioPlugin/Build/Products/Debug/CutdownAudio.app"
mkdir -p "$(dirname "$installed")"
publishing=$(mktemp -d "$PWD/build/audio-publish.XXXXXX")
# If rollback itself fails, preserve the previous signed app for manual recovery.
cleanup() {
  if [[ ! -e "$publishing/Previous.app" ]]; then rm -rf "$publishing"; fi
}
trap cleanup EXIT
/usr/bin/ditto "$candidate" "$publishing/CutdownAudio.app"
codesign --verify --deep --strict "$publishing/CutdownAudio.app"
check_host_stopped
if [[ -e "$installed" ]]; then mv "$installed" "$publishing/Previous.app"; fi
if ! mv "$publishing/CutdownAudio.app" "$installed"; then
  if [[ -e "$publishing/Previous.app" ]]; then mv "$publishing/Previous.app" "$installed"; fi
  exit 1
fi
rm -rf "$publishing/Previous.app"
printf '%s\n' "$installed"
