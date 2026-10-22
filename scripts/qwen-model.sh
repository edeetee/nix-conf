#!/usr/bin/env bash
# Fetch the Qwen3.6-35B-A3B GGUFs onto homeserver-edt's model directory.
#
# Runs *on the server* (where the files are needed); from the Mac:
#   ssh homeserver-edt.local 'cd ~/dev/nix-conf && ./scripts/qwen-model.sh'
#
# Resumable: a partial file continues where it stopped (`curl -C -`), and a
# completed file is checked against the SHA256 published in the HF LFS metadata,
# so re-running is free and safe.
#
#   ./scripts/qwen-model.sh            # all files below (~23 GiB)
#   ./scripts/qwen-model.sh q4 iq4     # a subset
#
# QWEN_MODELS_DIR overrides the destination, e.g. for a staging directory when
# /mnt/hdd/models does not exist yet. See plans/local-qwen.md §3.1 for why the
# directory is dedicated rather than a shared mount root.
set -euo pipefail

DEST=${QWEN_MODELS_DIR:-/mnt/hdd/models}
REPO=${QWEN_GGUF_REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}
BASE="https://huggingface.co/${REPO}/resolve/main"

# tag -> "filename sha256" (sizes as of 2026-10-21: 20.61 / 16.51 / 0.84 GiB)
declare -A FILES=(
  [q4]="Qwen3.6-35B-A3B-UD-Q4_K_M.gguf ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61"
  [iq4]="Qwen3.6-35B-A3B-UD-IQ4_XS.gguf 649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3"
  [mmproj]="mmproj-F16.gguf 8971ee4f331ff0a4c609374f32984b3d4e6dc086c0aa35f1d637fad1829e887f"
)

fetch() {
  local out=$1 want=$2
  if [[ -f "$out" ]] && [[ "$(sha256sum "$out" | cut -d' ' -f1)" == "$want" ]]; then
    echo "ok    $out (already verified)"
    return 0
  fi
  local i
  for i in 1 2 3 4 5 6; do
    echo "==    $(date -Is) attempt $i: $out"
    if curl -fsSL -C - --retry 5 --retry-delay 10 --retry-all-errors \
         --connect-timeout 30 --speed-time 120 --speed-limit 10240 \
         -o "$out" "$BASE/$out"; then
      break
    fi
    # A partial file that resumes into a corrupted whole never repairs itself.
    (( i >= 2 )) && rm -f "$out"
    sleep 20
  done
  local got
  got=$(sha256sum "$out" 2>/dev/null | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "FAIL  $out" >&2
    echo "      got  $got" >&2
    echo "      want $want" >&2
    return 1
  fi
  echo "ok    $out (sha256 verified, $(du -h "$out" | cut -f1))"
}

main() {
  # /mnt/hdd is `nofail`: if it is not mounted, mkdir would silently create the
  # directory on the root filesystem and fill it with 23 GiB.
  if [[ "$DEST" == /mnt/hdd/* ]] && ! mountpoint -q /mnt/hdd; then
    echo "error: /mnt/hdd is not mounted — refusing to write onto the root fs" >&2
    exit 1
  fi
  mkdir -p "$DEST"
  cd "$DEST"

  local tags=("$@")
  (( ${#tags[@]} )) || tags=(q4 iq4 mmproj)

  local t
  for t in "${tags[@]}"; do
    [[ -v FILES[$t] ]] || { echo "error: unknown tag '$t' (q4|iq4|mmproj)" >&2; exit 2; }
  done
  for t in "${tags[@]}"; do
    # shellcheck disable=SC2086 # FILES[$t] is deliberately two words
    fetch ${FILES[$t]}
  done

  echo "==    disk: $(df -h "$DEST" | tail -1)"
  echo "==    done $(date -Is)"
}

main "$@"
