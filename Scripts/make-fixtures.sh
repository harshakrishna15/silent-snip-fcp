#!/bin/bash
# Development fixtures only; FFmpeg is not linked to or shipped with Cutdown.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$PWD/build/Fixtures"
if [[ "${1:-}" == --audio-only ]]; then shift; fi
if [[ $# -eq 2 && "$1" == --output-dir ]]; then
  fixture_dir="$2"
elif [[ $# -ne 0 ]]; then
  echo 'Usage: Scripts/make-fixtures.sh [--output-dir DIRECTORY]' >&2
  exit 2
fi
mkdir -p "$fixture_dir"
fixture_dir=$(cd "$fixture_dir" && pwd)
# Original PCM media with two known pauses.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'aevalsrc=if(between(t\,2\,3.5)+between(t\,5\,7)\,0\,0.2*sin(2*PI*440*t)):s=48000:d=10' \
  -c:a pcm_s16le -ac 2 "$fixture_dir/Recording.wav"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=0.7' \
  -c:a pcm_s16le "$fixture_dir/OtherDialogue.wav"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'sine=frequency=220:sample_rate=48000:duration=10' \
  -c:a pcm_s16le "$fixture_dir/Music.wav"
python3 Scripts/make-fixture-xml.py --output-dir "$fixture_dir"
python3 Scripts/verify-audio-fixture.py --folder "$fixture_dir"
