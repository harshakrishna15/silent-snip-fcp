#!/bin/bash
# Wrap the verified release ZIP in a per-user macOS Installer package.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  --help|-h)
    echo 'Usage: Scripts/build-installer.sh'
    echo 'Builds dist/Silent Snip.pkg from dist/Silent Snip.zip (created by Scripts/build-app.sh).'
    exit 0 ;;
esac
[[ $# == 0 ]] || { echo 'Usage: Scripts/build-installer.sh' >&2; exit 2; }

archive="$PWD/dist/Silent Snip.zip"
installer="$PWD/dist/Silent Snip.pkg"
config="$PWD/Config/Installer"
[[ -f "$archive" ]] || { echo 'Silent Snip.zip is missing. Run Scripts/build-app.sh first.' >&2; exit 1; }
[[ ! -d "$installer" ]] || { echo 'A directory occupies the installer output path.' >&2; exit 1; }

work=$(mktemp -d "$PWD/dist/.installer.XXXXXX")
trap 'rm -rf "$work"' EXIT
/usr/bin/ditto -x -k "$archive" "$work/archive"
worker='Silent Snip.app'
frontend='Silent Snip Workflow Prototype.app'
source="$work/archive/Silent Snip"
payload="$work/payload"
mkdir "$payload"
for app in "$worker" "$frontend"; do
  [[ -d "$source/$app" && ! -L "$source/$app" ]] || {
    printf 'The release ZIP is missing a complete %s. Rebuild it with Scripts/build-app.sh.\n' "$app" >&2
    exit 1
  }
  mv "$source/$app" "$payload/"
done
python3 Scripts/check-workflow-prototype.py --app "$payload/$frontend" --worker "$payload/$worker" \
  --output "$work/Pair-Verification.json"
worker_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$payload/$worker/Contents/Info.plist")
frontend_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$payload/$frontend/Contents/Info.plist")

/usr/bin/pkgbuild --root "$payload" --component-plist "$config/Components.plist" \
  --install-location /Applications --identifier local.silentsnip.pkg \
  --version "$worker_version.$frontend_version" "$work/Apps.pkg"
/usr/bin/productbuild --distribution "$config/Distribution.xml" --package-path "$work" \
  --resources "$config/Resources" "$work/Silent Snip.pkg"
mv -f "$work/Silent Snip.pkg" "$installer"
printf 'Installer: %s\n' "$installer"
