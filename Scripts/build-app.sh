#!/bin/bash
# Assemble the AU-free worker and package its separate Workflow frontend.
# Never install into Applications, register packages, or grant access.
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
      echo 'Builds build/App/Silent Snip.app and a ZIP containing the worker and Workflow frontend.'
      echo '--stage builds only an inert worker candidate without changing the published app or ZIP.'
      echo '--reuse-components packages the existing staged helper and built Workflow frontend.'
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
    for name in 'Final Cut Pro' SilentSnip SilentSnipWorkflowPrototype SilentSnipWorkflowExtension; do
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
  [[ "$identity" == local.silentsnip.app ]] || { echo 'An unrelated app occupies the output path; it was kept.' >&2; exit 1; }
fi
if [[ "$reuse" == false ]]; then
  helper_args=(--stage)
  if [[ "$debug" == false ]]; then helper_args+=(--release); fi
  Scripts/build-helper.sh "${helper_args[@]}"
  if [[ "$stage" == false ]]; then Scripts/build-workflow-prototype.sh; fi
fi
helper="$PWD/build/Candidate/SilentSnipHelper.app"
frontend="$PWD/build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app"
[[ -x "$helper/Contents/MacOS/SilentSnip" ]] || { echo 'The staged helper is missing. Build without --reuse-components.' >&2; exit 1; }
[[ ! -L "$helper" ]] || { echo 'The staged helper must not be a symbolic link.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper/Contents/Info.plist") == local.silentsnip.helper.candidate ]] || { echo 'Unexpected helper identity.' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$helper/Contents/Info.plist") == \
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/Info.plist) &&
   $(/usr/libexec/PlistBuddy -c 'Print :SilentSnipWorkflowProtocolVersion' "$helper/Contents/Info.plist") == \
   $(/usr/libexec/PlistBuddy -c 'Print :SilentSnipWorkflowProtocolVersion' Config/Info.plist) ]] || {
  echo 'The staged helper metadata is out of date. Rebuild without --reuse-components.' >&2; exit 1;
}
codesign --verify --deep --strict "$helper"
mkdir -p build "$output"
work=$(mktemp -d "$PWD/build/.single-app.XXXXXX")
cleanup() { if [[ ! -e "$work/Previous.app" ]]; then rm -rf "$work"; fi; }
trap cleanup EXIT
app="$work/Silent Snip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$helper/Contents/MacOS/SilentSnip" "$app/Contents/MacOS/SilentSnip"
cp Config/Info.plist "$app/Contents/Info.plist"
cp Config/SilentSnip.sdef "$app/Contents/Resources/SilentSnip.sdef"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.silentsnip.app' "$app/Contents/Info.plist"
if [[ "$stage" == true ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Silent Snip Candidate' "$app/Contents/Info.plist"
  for key in CFBundleURLTypes CFBundleDocumentTypes com.apple.proapps.MediaAssetProtocol SilentSnipWorkflowProtocolVersion; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$app/Contents/Info.plist"
  done
fi
# The worker retains its existing URL/Share receiver and app identity. The
# separate Workflow frontend owns the sandboxed UI; no Audio Unit is embedded.
codesign --force --sign "${SILENT_SNIP_SIGNING_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$stage" == false ]]; then
  mkdir -p dist
  python3 Scripts/check-workflow-prototype.py --app "$frontend" --worker "$app" --output "$work/Pair-Verification.json"
  package="$work/Silent Snip"
  mkdir "$package"
  /usr/bin/ditto "$app" "$package/Silent Snip.app"
  /usr/bin/ditto "$frontend" "$package/Silent Snip Workflow Prototype.app"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package" "$work/Silent Snip.zip"
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
