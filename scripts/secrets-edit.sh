#!/usr/bin/env bash
# Edit homeserver-edt's secrets.yaml from a machine that is not the server.
#
#   ./scripts/secrets-edit.sh                    # homeserver-edt.local
#   ./scripts/secrets-edit.sh some-other-host    # override the ssh target
#
# Why not just `sops hosts/homeserver-edt/secrets.yaml` in this repo? Two
# independent reasons, both verified:
#
#   1. **The committed file is not encrypted to this machine.** Its metadata
#      lists only the server's keys, so a laptop cannot read it. Re-encrypting
#      the repo copy to fix that changes its ciphertext, which then collides
#      with (2).
#   2. **secrets.yaml is effectively server-owned.** The server carries
#      local-only commits (`deepseek api key`, `flake.local`) that add keys
#      absent from the repo copy, and sops-nix reads the *server's* working
#      copy. Committing an edit here and pushing it makes the next `nixup`
#      rebase collide on an encrypted file, which cannot be merged by hand.
#
# So the file that must be edited is the server's, and this fetches it, edits
# it, pushes it back and commits it there. Recipients are preserved by an edit
# of an existing file (sops takes them from the file's metadata — `updatekeys`
# is only needed after .sops.yaml changes), so no config file is required here.
#
# The age key it uses is the one sops finds by default: on macOS that is
# ~/Library/Application Support/sops/age/keys.txt (Go's os.UserConfigDir), not
# ~/.config/sops/age/keys.txt.
set -euo pipefail

HOST="${1:-homeserver-edt.local}"
# Overridable for testing against a throwaway checkout on the server.
REMOTE_REPO="${REMOTE_REPO:-dev/nix-conf}"
REL="hosts/homeserver-edt/secrets.yaml"

# The working copy is kept *outside* the checkout, so a fetched server file never
# shows up as a modification in `git status` — but the path still has to end in
# `hosts/homeserver-edt/secrets.yaml`, because that is what sops matches the
# `creation_rules` regex in .sops.yaml against. Without a matching rule, an
# interactive edit fails with "no matching creation rules found".
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/.sops.yaml"
LOCAL_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/nix-conf"
LOCAL="$LOCAL_ROOT/$REL"

mkdir -p "$(dirname "$LOCAL")"
chmod 700 "$LOCAL_ROOT" "$(dirname "$LOCAL")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching $HOST:$REL"
scp -q "$HOST:$REMOTE_REPO/$REL" "$LOCAL"
chmod 600 "$LOCAL"

# Refuse to hand the editor something we could not encrypt back.
sops -d "$LOCAL" > "$WORK/before"

echo "==> editing (Ctrl-C or an unchanged file leaves the server alone)"
# sops exits 200 when the editor changed nothing (and non-zero on error), so the
# exit status has to be inspected rather than left to `set -e`.
rc=0
sops --config "$CONFIG" "$LOCAL" || rc=$?
if [ "$rc" -eq 200 ]; then
  echo "==> no changes; server untouched"
  exit 0
fi
if [ "$rc" -ne 0 ]; then
  echo "!! sops failed (exit $rc); server untouched" >&2
  exit "$rc"
fi

sops -d "$LOCAL" > "$WORK/after"

# A no-op edit still rewrites every ciphertext (new IVs), so compare plaintext.
# Without this, quitting the editor would churn the file and the commit below.
if cmp -s "$WORK/before" "$WORK/after"; then
  echo "==> no changes; server untouched"
  exit 0
fi

echo "==> pushing to $HOST"
scp -q "$LOCAL" "$HOST:$REMOTE_REPO/$REL"

# Validate on the far side before committing: if the file we pushed is not
# decryptable there, restore git's copy and fail loudly.
if ! ssh "$HOST" "cd ~/$REMOTE_REPO && sops -d $REL > /dev/null"; then
  echo "!! $HOST cannot decrypt what we pushed — restoring from git" >&2
  ssh "$HOST" "cd ~/$REMOTE_REPO && git checkout -- $REL"
  exit 1
fi

MSG="secrets: edit from $(hostname -s)"
ssh "$HOST" "cd ~/$REMOTE_REPO && git commit -q -m '$MSG' -- $REL"
echo "==> committed on $HOST:"
ssh "$HOST" "cd ~/$REMOTE_REPO && git log --oneline -1"
