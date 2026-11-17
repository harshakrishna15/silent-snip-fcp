#!/bin/bash
# Offscreen controller policy tests. No prototype/FCP build, registration,
# window, UI event, SDK entry point, or production settings store is used.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# != 0 ]]; then
  echo 'Usage: bash WorkflowPrototype/Tests/run-controller-tests.sh' >&2
  exit 2
fi
sdk="${SILENT_SNIP_WORKFLOW_SDK:-/Library/Developer/SDKs/WorkflowExtensionSDK.sdk}"
[[ -f "$sdk/Library/Frameworks/ProExtensionHost.framework/Headers/FCPXHost.h" ]] || {
  echo 'Apple Workflow Extensions SDK headers are required.' >&2
  exit 1
}
output="$PWD/build/WorkflowPrototype/Tests"
[[ ! -L "$PWD/build/WorkflowPrototype" && ! -L "$output" ]] || {
  echo 'Controller test output must not be symlinked.' >&2
  exit 1
}
mkdir -p "$output"
mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
# No modules: use only the public SDK declarations, without auto-linking its
# header-only ProExtensionHost framework. The singleton is the in-memory stub.
xcrun clang -arch arm64 -isysroot "$mac_sdk" -mmacosx-version-min=14.0 \
  -fobjc-arc -fno-modules -Wall -Wextra -Wno-unused-parameter \
  -I "$sdk/usr/include" -F "$sdk/Library/Frameworks" \
  -I WorkflowPrototype/Tests/Support WorkflowPrototype/Tests/ControllerTests.m \
  -framework AppKit -framework Foundation -framework CoreMedia -framework CoreServices -framework QuartzCore \
  -o "$output/ControllerTests"
"$output/ControllerTests"
