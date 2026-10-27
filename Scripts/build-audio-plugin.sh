#!/bin/bash
# Build the embedded extension only; the containing app is assembled by build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=Release
for argument in "$@"; do
  case "$argument" in
    --stage) ;; # Retained for existing developer commands; no app is published here.
    --debug) configuration=Debug ;;
    --help|-h)
      echo 'Usage: Scripts/build-audio-plugin.sh [--stage] [--debug] [Xcode build settings]'
      echo 'Builds the sandboxed extension into build/Candidate/AudioPlugin without registering it.'
      exit 0 ;;
  esac
done
extra=()
for argument in "$@"; do
  case "$argument" in --stage|--debug) ;; *) extra+=("$argument") ;; esac
done
candidate="$PWD/build/Candidate/AudioPlugin/SilentSnipAudio.appex"
pattern=$(printf '%s' "$candidate/Contents/MacOS/SilentSnipAudio" | /usr/bin/sed 's/[][\.^$*+?(){}|]/\\&/g')
if /usr/bin/pgrep -f "^${pattern}([[:space:]]|$)" >/dev/null; then
  echo 'The staged audio extension is running. Quit its host before rebuilding.' >&2; exit 1
else
  status=$?
  [[ "$status" == 1 ]] || { echo 'Cannot inspect the staged audio extension; no build was started.' >&2; exit 1; }
fi
mkdir -p build/AudioPluginStage build/module-cache build/Candidate/AudioPlugin
xcodebuild -project SilentSnipAudio.xcodeproj -scheme SilentSnipAudio -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/build/AudioPluginStage" \
    CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
    CODE_SIGN_IDENTITY="${SILENT_SNIP_SIGNING_IDENTITY:--}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${SILENT_SNIP_DEVELOPMENT_TEAM:-}" \
    ${extra[@]+"${extra[@]}"} \
    "CONFIGURATION_BUILD_DIR=$PWD/build/Candidate/AudioPlugin" DONT_REGISTER_WITH_LAUNCH_SERVICES=YES build
codesign --verify --deep --strict "$candidate"
printf '%s\n' "$candidate"
