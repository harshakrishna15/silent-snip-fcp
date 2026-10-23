#!/bin/bash
# Developer convenience entry point: one app, then optional local registration.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=false
release=false
for argument in "$@"; do
  case "$argument" in
    --release) release=true ;;
    --stage) stage=true ;;
    --help|-h)
      echo 'Usage: Scripts/build.sh [--release] [--stage]'
      echo 'Builds one Silent Snip.app with a Debug executable and extension by default.'
      echo '--release builds both components in Release; --stage keeps the published app and registrations unchanged.'
      echo 'Normal builds require Final Cut and Silent Snip to be closed.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
arguments=()
if [[ "$release" == false ]]; then arguments+=(--debug); fi
if [[ "$stage" == true ]]; then arguments+=(--stage); fi
Scripts/build-app.sh ${arguments[@]+"${arguments[@]}"}
if [[ "$stage" == false ]]; then Scripts/register-local.sh; fi
