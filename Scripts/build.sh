#!/bin/bash
# Incremental development build of both components, followed by registration.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: Scripts/build.sh [--release] [--stage]

Build both Cutdown components and register them for Final Cut Pro.
Default: Debug helper for faster development builds; Debug audio plug-in.
  --release  Optimize the helper for normal use (audio remains Debug).
  --stage    Build candidates only; do not publish or explicitly register them.
  --help     Show this help.

Quit Final Cut Pro and Cutdown before a normal build. Existing Swift/Xcode
caches are reused. No clean, tests, permissions changes, or app launches run.
Xcode may register a staged audio candidate; run a normal build before using
Final Cut again. First-time permissions and Share setup are still required.
EOF
}

stage=false
helper_args=()
audio_args=()
for argument in "$@"; do
  case "$argument" in
    --release) helper_args+=(--release) ;;
    --stage) stage=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

# Check both apps before either child script publishes an installed bundle.
# The child scripts also recheck at publication time to catch later launches.
require_stopped() {
  local app_name="$1" status
  if /usr/bin/pgrep -x "$app_name" >/dev/null; then
    printf 'Quit %s before building, or use --stage for candidates.\n' "$app_name" >&2
    exit 1
  else
    status=$?
    if [[ "$status" != 1 ]]; then
      echo 'Cannot verify running apps. Retry with process-list access; no build was started.' >&2
      exit 1
    fi
  fi
}

if [[ "$stage" == true ]]; then
  helper_args+=(--stage)
  audio_args+=(--stage)
else
  require_stopped 'Final Cut Pro'
  require_stopped Cutdown
fi

SECONDS=0
echo 'Building Cutdown helper…'
# The guarded expansion supports empty arrays with nounset on macOS Bash 3.2.
Scripts/build-helper.sh ${helper_args[@]+"${helper_args[@]}"}
echo 'Building Cutdown Audio…'
Scripts/build-audio-plugin.sh ${audio_args[@]+"${audio_args[@]}"}
if [[ "$stage" == true ]]; then
  printf 'Candidate builds complete in %ss. Run a normal build before live use.\n' "$SECONDS"
else
  echo 'Registering Cutdown…'
  Scripts/register-local.sh
  printf 'Build and registration complete in %ss. You can reopen Final Cut Pro.\n' "$SECONDS"
fi
