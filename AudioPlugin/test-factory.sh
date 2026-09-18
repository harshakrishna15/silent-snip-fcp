#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/AudioPlugin build/module-cache
compile=(-fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/module-cache" -mmacosx-version-min=14.0)
xcrun clang "${compile[@]}" -c AudioPlugin/Extension/CutdownAudioUnitFactory.m -o build/AudioPlugin/AudioUnitFactory.o
xcrun clang "${compile[@]}" -c AudioPlugin/Extension/CutdownReviewConnection.m -o build/AudioPlugin/ReviewConnection.o
xcrun clang "${compile[@]}" -c AudioPlugin/Tests/FactoryTests.m -o build/AudioPlugin/FactoryTests.o
xcrun clang++ -std=c++20 "${compile[@]}" \
    -framework Foundation -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit -framework AppKit -framework UniformTypeIdentifiers \
    AudioPlugin/Extension/CutdownAudioUnit.mm build/AudioPlugin/ReviewConnection.o build/AudioPlugin/AudioUnitFactory.o build/AudioPlugin/FactoryTests.o \
    -o build/AudioPlugin/FactoryTests
build/AudioPlugin/FactoryTests AudioPlugin/Extension/Info.plist
