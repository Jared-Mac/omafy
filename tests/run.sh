#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

node --test tests/service.test.js
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash -n bin/omafy-player

if command -v quickshell >/dev/null; then
  scratch=$(mktemp -d)
  trap 'rm -rf -- "$scratch"' EXIT
  mkdir -m 700 "$scratch/runtime"
  mkdir "$scratch/bin"
  cp Service.qml Spotify.js "$scratch/"
  cp bin/omafy-auth "$scratch/bin/"
  cp tests/smoke.qml "$scratch/shell.qml"
  # Never read real credentials or connect to the desktop session in this test.
  if ! QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= WAYLAND_DISPLAY= DISPLAY= XDG_CONFIG_HOME="$scratch/config" \
    XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
    XDG_RUNTIME_DIR="$scratch/runtime" \
    timeout 10s quickshell --no-color -p "$scratch" >"$scratch/smoke.log" 2>&1; then
    cat "$scratch/smoke.log"
    exit 1
  fi
  cat "$scratch/smoke.log"
  grep -q 'OMAFY_SMOKE_PASSED' "$scratch/smoke.log"
  if grep -Eq 'OMAFY_SMOKE_FAILED|ReferenceError|TypeError|Binding loop|Failed to load' "$scratch/smoke.log"; then exit 1; fi
fi
