#!/usr/bin/env bash
# Build nix-conf's `sink-pi` system and deploy it to the Pi.
#
#   ./scripts/sink-pi-switch.sh                  # sink@sink-pi.local
#   ./scripts/sink-pi-switch.sh sink@192.168.1.27
#
# It runs the sink repository's own deploy script, pointed at this repository:
#
#   sink/nix/switch.sh --flake <this repo> --dir sink-pi \
#     --sink-repo <sink checkout> [target]
#
# The configuration is a *split flake* at `sink-pi/flake.nix`, and `--dir sink-pi` is
# what names it: the whole repository is mounted and the reference is built as
# `git+file:///src?dir=sink-pi#...`, so the sub-flake can still read ../hosts/sink-pi
# and ../modules/nixos. The top-level flake has no `sink` input, which is the point -
# evaluating it (nixup on the homeserver, for one) never needs the private repository.
# Do not pass `sink-pi` as the --flake path instead: a bare subdirectory is a *path*
# flake, which would see untracked files and lose the tracked-only semantics that let
# hosts/sink-pi/local.nix hold the WiFi key uncommitted.
#
# It builds `nixosConfigurations.sink-pi` in an aarch64 container, with the sub-flake's
# `sink` input overridden by the local sink checkout, and copies only the delta to the
# Pi. That override is the point: a change in the sink working tree - committed or not,
# as long as the file is tracked - is what gets built, without touching either
# flake.lock.
#
# SINK_REPO points at the sink checkout; the default is ~/dev/sink, and it is needed
# for the deploy script itself as well as for the override. SINK_HOST overrides the
# nixosConfigurations attribute name (default `sink-pi`).
set -euo pipefail

conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sink="${SINK_REPO:-$HOME/dev/sink}"
host="${SINK_HOST:-sink-pi}"

if [ ! -x "$sink/nix/switch.sh" ]; then
  echo "sink-pi-switch: no deploy script at $sink/nix/switch.sh" >&2
  echo "                set SINK_REPO to the sink checkout" >&2
  exit 1
fi

exec "$sink/nix/switch.sh" \
  --flake "$conf" \
  --dir sink-pi \
  --host "$host" \
  --sink-repo "$sink" \
  "$@"
