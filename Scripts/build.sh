#!/bin/bash
# Developer convenience entry point: worker/frontend pair and local registration.
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
      echo 'Builds an AU-free Debug worker and Release Workflow frontend, then registers both.'
      echo '--release builds the worker in Release; the Workflow frontend always uses Release.'
      echo '--stage builds only an inert worker candidate; published apps, ZIP, and registrations stay unchanged.'
      echo 'Normal builds require Final Cut and both Silent Snip apps to be closed.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
arguments=()
if [[ "$release" == false ]]; then arguments+=(--debug); fi
if [[ "$stage" == true ]]; then arguments+=(--stage); fi
Scripts/build-app.sh ${arguments[@]+"${arguments[@]}"}
if [[ "$stage" == false ]]; then Scripts/register-local.sh; fi
