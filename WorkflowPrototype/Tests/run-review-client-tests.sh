#!/bin/bash
# Offline client tests only: all Launch Services/DNC/timer boundaries are fake.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 ]] || { echo 'Usage: bash WorkflowPrototype/Tests/run-review-client-tests.sh' >&2; exit 2; }
output="$PWD/build/WorkflowPrototype/Tests"
[[ ! -L "$PWD/build/WorkflowPrototype" && ! -L "$output" ]] || { echo 'Test output must not be symlinked.' >&2; exit 1; }
mkdir -p "$output"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -fobjc-arc -fno-modules \
  -Wall -Wextra -Wno-unused-parameter -I AudioPlugin/Extension \
  WorkflowPrototype/Tests/ReviewClientTests.m WorkflowPrototype/Extension/WorkflowReviewClient.m \
  AudioPlugin/Extension/SilentSnipReviewConnection.m -framework AppKit -framework Foundation \
  -o "$output/ReviewClientTests"
"$output/ReviewClientTests"
