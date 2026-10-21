#!/bin/bash
# Remove this checkout's local installation; never edit Final Cut projects.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir=$(pwd -P)
build_dir="$repo_dir/build"
dry_run=false
remove_data=false

usage() {
  cat <<'HELP'
Usage: Scripts/uninstall-local.sh [--dry-run] [--remove-data]

Unregister and remove Silent Snip app bundles built in this checkout.
  --dry-run      Show the commands without changing files or registrations.
  --remove-data  Also erase this user's Silent Snip settings, saved results,
                 recovery XML, shared deliveries, sandbox containers, and caches.
  --help         Show this help.

Quit Final Cut Pro and Silent Snip first. No apps are stopped automatically.
By default, saved settings and results are kept. Source code, build caches,
source media, integration evidence, and Final Cut libraries are always kept.
App copies outside this checkout are not removed. See docs/setup.md#uninstall
for removing the Final Cut Share destination and macOS privacy entries.
HELP
}

for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=true ;;
    --remove-data) remove_data=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { printf '%s\n' "$*" >&2; exit 1; }
run() {
  if [[ "$dry_run" == true ]]; then
    printf 'Would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
require_stopped() {
  local name
  [[ "$dry_run" == false ]] || return 0
  for name in 'Final Cut Pro' Cutdown CutdownAudio CutdownAudioExtension; do
    if /usr/bin/pgrep -x "$name" >/dev/null; then
      fail 'Quit Final Cut Pro, Silent Snip, and its Audio Unit before uninstalling. No process was stopped.'
    else
      local status=$?
      [[ "$status" == 1 ]] || fail 'Cannot inspect running apps. Retry with process-list access; no further changes were made.'
    fi
  done
}

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pluginkit=/usr/bin/pluginkit
plistbuddy=/usr/libexec/PlistBuddy
apps=()
extensions=()
preference_domains=()

# Find app copies produced by normal, staged, or diagnostic builds. Never follow
# directory symlinks or enter media libraries/export bundles. The identity check
# below excludes unrelated apps even if they happen to use our filenames.
[[ ! -L "$build_dir" ]] || fail 'The build directory is a symlink. Uninstall from the original checkout instead.'
if [[ -d "$build_dir" ]]; then
  manifest=$(mktemp "${TMPDIR:-/tmp}/silent-snip-uninstall.XXXXXX")
  trap 'rm -f "$manifest"' EXIT
  /usr/bin/find "$build_dir" \( -name '*.fcpbundle' -o -name '*.fcpxmld' \) -prune -o \
    -type d -name '*.app' -prune -print0 > "$manifest"
  while IFS= read -r -d '' app; do
    [[ -f "$app/Contents/Info.plist" ]] || continue
    identity=$("$plistbuddy" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") || fail "Cannot inspect bundle: $app"
    extension=''
    case "$identity" in
      local.cutdown.helper|local.cutdown.helper.candidate) ;;
      local.cutdown.audio)
        [[ ! -L "$app/Contents" && ! -L "$app/Contents/PlugIns" ]] || fail "Audio bundle contains a symlinked extension parent; nothing was removed: $app"
        extension="$app/Contents/PlugIns/CutdownAudioExtension.appex"
        if [[ -e "$extension" || -L "$extension" ]]; then
          [[ ! -L "$extension" && -d "$extension" ]] || fail "Cannot safely inspect extension: $extension"
          extension_identity=$("$plistbuddy" -c 'Print :CFBundleIdentifier' "$extension/Contents/Info.plist") || fail "Cannot inspect extension: $extension"
          [[ "$extension_identity" == local.cutdown.audio.extension ]] || fail "Unexpected extension identity at $extension; nothing was removed."
        else
          extension=''
        fi
        ;;
      *) continue ;;
    esac
    apps+=("$app")
    extensions+=("$extension")
  done < "$manifest"
fi

# Validate every parent before data removal. rm removes a final symlink itself,
# but must never traverse a symlinked Library or category into another location.
if [[ "$remove_data" == true ]]; then
  [[ "$HOME" == /* && "$HOME" != / ]] || fail 'Cannot determine a safe user home directory.'
  [[ -x /usr/bin/defaults ]] || fail 'The macOS defaults tool is missing.'
  user_library="$HOME/Library"
  for parent in "$user_library" "$user_library/Application Support" "$user_library/Containers" \
    "$user_library/Caches" "$user_library/Preferences" "$user_library/Saved Application State" \
    "$user_library/Application Scripts"; do
    [[ ! -L "$parent" ]] || fail "Data directory is a symlink; remove its app data manually: $parent"
  done
  for identity in local.cutdown.helper local.cutdown.helper.candidate local.cutdown.audio local.cutdown.audio.extension; do
    if /usr/bin/defaults read "$identity" >/dev/null 2>&1; then
      preference_domains+=("$identity")
    elif [[ -e "$user_library/Preferences/$identity.plist" || -L "$user_library/Preferences/$identity.plist" ]]; then
      fail "Cannot read app preferences for $identity; nothing was removed."
    fi
  done
fi

if [[ ${#apps[@]} -gt 0 ]]; then
  for tool in "$lsregister" "$pluginkit" "$plistbuddy"; do
    [[ -x "$tool" ]] || fail "Required macOS tool is missing: $tool"
  done
fi
require_stopped

# Finish unregistering before deleting any bundle. A tool failure leaves apps
# available for a retry or re-registration. An already-absent extension is OK.
for ((index=0; index<${#apps[@]}; index++)); do
  extension="${extensions[$index]}"
  if [[ -n "$extension" ]]; then
    if ! run "$pluginkit" -r "$extension"; then
      registry=$("$pluginkit" -m -A -D -v -i local.cutdown.audio.extension) || fail 'Cannot verify Audio Unit removal; app bundles were kept.'
      [[ -z "${registry//[[:space:]]/}" ]] || fail "Audio Unit removal failed and registrations remain; app bundles were kept: $extension"
    fi
  fi
  run "$lsregister" -u "${apps[$index]}" || fail 'App unregistration failed; app bundles were kept. Retry uninstall or run Scripts/register-local.sh to restore registration.'
done
for app in ${apps[@]+"${apps[@]}"}; do
  require_stopped
  run /bin/rm -rf -- "$app"
done

if [[ "$remove_data" == true ]]; then
  require_stopped
  for path in "$user_library/Application Support/Cutdown" "$user_library/Application Support/Cutdown Audio"; do
    if [[ -e "$path" || -L "$path" ]]; then run /bin/rm -rf -- "$path"; fi
  done
  for identity in ${preference_domains[@]+"${preference_domains[@]}"}; do
    run /usr/bin/defaults delete "$identity"
  done
  for identity in local.cutdown.helper local.cutdown.helper.candidate local.cutdown.audio local.cutdown.audio.extension; do
    for path in "$user_library/Containers/$identity" "$user_library/Caches/$identity" \
      "$user_library/Saved Application State/$identity.savedState" "$user_library/Application Scripts/$identity"; do
      if [[ -e "$path" || -L "$path" ]]; then run /bin/rm -rf -- "$path"; fi
    done
  done
fi

if [[ "$dry_run" == true ]]; then
  echo 'Preview complete. No app files, saved data, or registrations changed.'
else
  echo "Removed ${#apps[@]} Silent Snip app bundle(s) from this checkout and unregistered them."
  if [[ "$remove_data" == true ]]; then
    echo 'Removed local app data. Source media, Final Cut libraries, integration evidence, and developer build caches were kept.'
  else
    echo 'Saved settings and results were kept. Add --remove-data to erase them.'
  fi
fi
echo 'Finish by removing the Silent Snip Share destination and its macOS privacy entries; see docs/setup.md#uninstall.'
