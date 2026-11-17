#!/bin/bash
# Offline lease tests include the real transport with fake external boundaries.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 ]] || { echo 'Usage: bash WorkflowPrototype/Tests/run-window-client-tests.sh' >&2; exit 2; }
output="$PWD/build/WorkflowPrototype/Tests"
[[ ! -L "$PWD/build/WorkflowPrototype" && ! -L "$output" ]] || { echo 'Test output must not be symlinked.' >&2; exit 1; }
mkdir -p "$output"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -fobjc-arc -fno-modules \
  -Wall -Wextra -Wno-unused-parameter WorkflowPrototype/Tests/WindowClientTests.m \
  -framework Foundation -framework CoreFoundation -o "$output/WindowClientTests"
"$output/WindowClientTests"
