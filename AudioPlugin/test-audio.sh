#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/AudioPlugin build/module-cache
xcrun clang++ -std=c++20 -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/module-cache" \
    -mmacosx-version-min=14.0 -framework Foundation -framework AudioToolbox -framework AVFoundation \
    AudioPlugin/Extension/CutdownAudioUnit.mm AudioPlugin/Tests/AudioUnitTests.mm \
    -o build/AudioPlugin/AudioUnitTests
build/AudioPlugin/AudioUnitTests
