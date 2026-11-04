#!/bin/bash
# Build an isolated read-only Workflow Extension. Never install or register it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 0 ]]; then
  echo 'Usage: Scripts/build-workflow-prototype.sh' >&2
  exit 2
fi
sdk="${SILENT_SNIP_WORKFLOW_SDK:-/Library/Developer/SDKs/WorkflowExtensionSDK.sdk}"
[[ -f "$sdk/usr/lib/libProExtension.a" && -f "$sdk/Library/Frameworks/ProExtensionHost.framework/Headers/FCPXHost.h" ]] || {
  echo 'Install Apple’s Workflow Extensions SDK before building this prototype.' >&2; exit 1;
}
root="$PWD/build/WorkflowPrototype"
destination="$root/Products/Silent Snip Workflow Prototype.app"
for process in SilentSnipWorkflowExtension SilentSnipWorkflowPrototype; do
  if /usr/bin/pgrep -x "$process" >/dev/null; then
    echo 'Close the Workflow Prototype and its extension before rebuilding.' >&2; exit 1
  else
    result=$?
    [[ "$result" == 1 ]] || { echo 'Cannot inspect the prototype process; no build was started.' >&2; exit 1; }
  fi
done
mkdir -p "$root/Products" "$root/ModuleCache"
[[ ! -L "$root" && ! -L "$root/Products" && ! -L "$destination" ]] || { echo 'Prototype output must not be symlinked.' >&2; exit 1; }
if [[ -e "$destination" ]]; then
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist") == local.silentsnip.workflowprototype ]] || {
    echo 'An unrelated app occupies the prototype path.' >&2; exit 1;
  }
fi
swift build --scratch-path build/swift -c release --target SilentSnipWorkflowModel
bin=$(swift build --scratch-path build/swift -c release --show-bin-path)
module_path="$bin"
model_objects=("$bin/SilentSnipWorkflowModel.o")
if [[ -d "$bin/Modules" ]]; then
  module_path="$bin/Modules"
  model_objects=("$bin/SilentSnipWorkflowModel.build/"*.swift.o)
fi
[[ -f "${model_objects[0]}" ]] || { echo 'The built workflow model objects are missing.' >&2; exit 1; }
work=$(mktemp -d "$root/.Build.XXXXXX")
app="$work/Silent Snip Workflow Prototype.app"
extension="$app/Contents/PlugIns/SilentSnipWorkflowExtension.appex"
mkdir -p "$app/Contents/MacOS" "$extension/Contents/MacOS"
cp WorkflowPrototype/Container/Info.plist "$app/Contents/Info.plist"
cp WorkflowPrototype/Extension/Info.plist "$extension/Contents/Info.plist"
sysroot=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -swift-version 5 -O -parse-as-library -emit-object \
  -module-name SSWorkflowPersistence -target arm64-apple-macosx14.0 -sdk "$sysroot" \
  -I "$module_path" -module-cache-path "$root/ModuleCache" -emit-objc-header -emit-objc-header-path "$work/SSWorkflowPersistence-Swift.h" \
  WorkflowPrototype/Extension/WorkflowSettingsBridge.swift -o "$work/Persistence.o"
xcrun clang -arch arm64 -isysroot "$sysroot" -mmacosx-version-min=14.0 -fobjc-arc \
  -fmodules -fmodules-cache-path="$root/ModuleCache" -fapplication-extension \
  -I "$work" -I "$sdk/usr/include" -F "$sdk/Library/Frameworks" \
  -c WorkflowPrototype/Extension/WorkflowViewController.m -o "$work/ViewController.o"
xcrun swiftc -target arm64-apple-macosx14.0 -sdk "$sysroot" \
  "$work/ViewController.o" "$work/Persistence.o" "${model_objects[@]}" \
  -L "$sdk/usr/lib" -lProExtension -lc++ -framework AppKit -framework CoreMedia -framework CoreServices \
  -Xlinker -e -Xlinker _ProExtensionMain \
  -o "$extension/Contents/MacOS/SilentSnipWorkflowExtension"
xcrun clang -arch arm64 -isysroot "$sysroot" -mmacosx-version-min=14.0 -fobjc-arc \
  -framework AppKit WorkflowPrototype/Container/main.m -o "$app/Contents/MacOS/SilentSnipWorkflowPrototype"
identity="${SILENT_SNIP_SIGNING_IDENTITY:--}"
codesign --force --sign "$identity" --entitlements WorkflowPrototype/Extension/Sandbox.entitlements "$extension"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
if [[ -e "$destination" ]]; then mv "$destination" "$work/Previous.package"; fi
mv "$app" "$destination"
printf 'Built isolated prototype (not installed or registered):\n%s\n' "$destination"
