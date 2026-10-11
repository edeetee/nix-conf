#!/usr/bin/env bash
# Build the SD card image for nix-conf's `sink-pi` host.
#
#   ./scripts/sink-pi-image.sh
#   ./scripts/sink-pi-image.sh --out /tmp/sink-pi.img
#
# It runs the sink repository's own image build, pointed at this repository:
#
#   sink/nix/build-image.sh --flake <this repo> --dir sink-pi \
#     --sink-repo <sink checkout>
#
# `--dir sink-pi` names the split flake at `sink-pi/flake.nix`; the header of
# scripts/sink-pi-switch.sh explains why the path form would be wrong.
#
# The image is written to the *sink* checkout's build/sink-pi.img by default, which
# is where sink/nix/flash-sd.sh looks for it, so the next step is:
#
#   SINK_REPO=~/dev/sink ~/dev/sink/nix/flash-sd.sh
#
# SINK_REPO points at the sink checkout; the default is ~/dev/sink.
set -euo pipefail

conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sink="${SINK_REPO:-$HOME/dev/sink}"

if [ ! -x "$sink/nix/build-image.sh" ]; then
  echo "sink-pi-image: no build script at $sink/nix/build-image.sh" >&2
  echo "               set SINK_REPO to the sink checkout" >&2
  exit 1
fi

exec "$sink/nix/build-image.sh" \
  --flake "$conf" \
  --dir sink-pi \
  --image images.sink-pi \
  --sink-repo "$sink" \
  "$@"
