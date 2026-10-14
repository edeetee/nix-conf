#!/usr/bin/env bash
# Deploy this repo's homeserver-edt configuration, from this machine.
#
#   ./scripts/deploy-server.sh              # push, pull, pre-flight, switch
#   ./scripts/deploy-server.sh --no-push    # deploy what is already pushed
#
# This is the non-interactive counterpart to the `push-server` alias. That one
# prompts for the sudo password and pipes it to remote sudo; this one relies on
# the NOPASSWD'd `nixos-deploy` wrapper installed by
# hosts/homeserver-edt/deploy.nix, so it works from scripts and agents.
#
# Both build *on the server* and switch there. That is not a preference: this
# Mac is aarch64-darwin with no x86_64-linux builder (no /etc/nix/machines, and
# nix.linux-builder is disabled), so a build here is impossible.
#
# Bootstrap note: `sudo nixos-deploy` only exists once this host's
# configuration has been switched with it, so the *first* deploy of
# hosts/homeserver-edt/deploy.nix has to go through `nixup` on the server (or
# the push-server alias). Until then this script stops at the switch with
# "a password is required".
#
# It refuses to deploy when the configuration declares a sops secret that is
# missing from the server's secrets.yaml. sops-nix catches that while building
# manifest.json — before anything is switched, so the failure is harmless — but
# it costs a full evaluation and the error is opaque ("the key X cannot be
# found"). Add the secret with ./scripts/secrets-edit.sh.
set -euo pipefail

HOST="${HOST:-homeserver-edt.local}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_REPO="~/dev/nix-conf"
REMOTE_SOPS_FILE="hosts/homeserver-edt/secrets.yaml"

push=1
if [ "${1:-}" = "--no-push" ]; then
  push=0
fi

cd "$REPO"

# ── Local state ────────────────────────────────────────────────────────────
if [ -n "$(git status --porcelain)" ]; then
  echo "==> note: uncommitted changes are NOT deployed:"
  git status --short | sed 's/^/    /'
fi

if [ "$push" = 1 ]; then
  if [ -n "$(git log --oneline origin/main..HEAD)" ]; then
    echo "==> pushing to origin/main:"
    git log --oneline origin/main..HEAD | sed 's/^/    /'
    git push origin main
  else
    echo "==> nothing to push"
  fi
fi

# ── Server state (as edeetee; the privileged switch does no git) ───────────
echo "==> pulling on $HOST"
ssh "$HOST" "git -C $REMOTE_REPO pull --rebase --quiet && git -C $REMOTE_REPO --no-pager log --oneline -1"

# Pre-flight: every `sops.secrets.<name>` declared anywhere in the checkout must
# exist in the default sops file. All secrets here share one file — see
# modules/nixos/sops.nix.
declared="$(ssh "$HOST" "cd $REMOTE_REPO && grep -rhoE 'sops\.secrets\.[A-Za-z0-9_-]+' --include='*.nix' . | sed 's/^sops\.secrets\.//' | sort -u")"
present="$(ssh "$HOST" "cd $REMOTE_REPO && sops -d $REMOTE_SOPS_FILE | grep -oE '^[A-Za-z0-9_-]+:' | tr -d ':' | sort -u")"
missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$present"))"
if [ -n "$missing" ]; then
  echo "!! refusing to deploy: declared in Nix but missing from $REMOTE_SOPS_FILE:" >&2
  printf '     %s\n' $missing >&2
  echo "   add it with ./scripts/secrets-edit.sh" >&2
  exit 1
fi
echo "==> secrets pre-flight OK"

# ── Switch ─────────────────────────────────────────────────────────────────
# The store path is resolved first so the command matches the sudoers rule
# exactly: the rule names a /nix/store path, while this is invoked through the
# /run/current-system/sw/bin symlink (which points somewhere new after every
# rebuild).
echo "==> switching on $HOST"
if ! ssh "$HOST" 'sudo -n "$(readlink -f "$(command -v nixos-deploy)")"'; then
  echo "!! switch failed." >&2
  echo "   If that was 'a password is required', this host's checkout has not yet" >&2
  echo "   been switched with hosts/homeserver-edt/deploy.nix — run 'nixup' on the" >&2
  echo "   server (or use the push-server alias, which prompts) for the first one." >&2
  exit 1
fi
