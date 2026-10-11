#!/usr/bin/env bash
# Build nix-conf's `sink-pi` system and deploy it to the Pi.
#
#   ./scripts/sink-pi-switch.sh                  # sink@sink-pi.local
#   ./scripts/sink-pi-switch.sh sink@192.168.1.27
#
# It runs the sink repository's own deploy script, pointed at this repository:
#
#   sink/nix/switch.sh --flake <this repo> --sink-repo <sink checkout> [target]
#
# which builds `nixosConfigurations.sink-pi` in an aarch64 container, with the
# flake's `sink` input overridden by the local sink checkout, and copies only the
# delta to the Pi. That override is the point: a change in the sink working tree -
# committed or not, as long as the file is tracked - is what gets built, without
# touching nix-conf's flake.lock.
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
  --host "$host" \
  --sink-repo "$sink" \
  "$@"
