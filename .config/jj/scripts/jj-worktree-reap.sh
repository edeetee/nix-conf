#!/bin/bash
# jj-worktree-reap.sh — GC idle, safe-to-drop jj worktrees under <repo>/.jj-worktrees.
#
# A worktree is reaped only when BOTH hold:
#   - idle:  its .jj/working_copy mtime is older than MAX_IDLE_SECONDS, AND
#   - safe:  removing it abandons no work — every non-empty commit in @'s history
#            is kept alive by some bookmark or tag (so it survives the forget).
#
# Idle-based, so it's crash-safe (a killed agent stops bumping the mtime). Uses
# --ignore-working-copy so it never snapshots (no op-log churn / forks).
#
# Usage: jj-worktree-reap.sh [--apply] [repo_root]
#   dry-run by default (prints what it WOULD remove); --apply actually removes.
#   MAX_IDLE_SECONDS env overrides the default (604800 = 7 days).
set -u

APPLY=0
REPO=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    *) REPO="$a" ;;
  esac
done

REPO="${REPO:-$(jj workspace root 2>/dev/null)}"
# If invoked from inside a worktree, walk back to the main repo.
case "$REPO" in *"/.jj-worktrees/"*) REPO="${REPO%/.jj-worktrees/*}" ;; esac
[ -n "$REPO" ] && [ -d "$REPO/.jj-worktrees" ] || exit 0

MAX_IDLE="${MAX_IDLE_SECONDS:-604800}"
now=$(date +%s)

for w in "$REPO"/.jj-worktrees/*/; do
  [ -d "$w" ] || continue
  n=$(basename "$w")
  [ "$n" = "default" ] && continue
  [ -d "$w/.jj/working_copy" ] || continue

  m=$(stat -f %m "$w/.jj/working_copy" 2>/dev/null || echo 0)
  idle=$(( now - m ))
  [ "$idle" -ge "$MAX_IDLE" ] || continue   # touched recently -> keep

  # Abandon-safety (no snapshot): keep if any non-empty commit isn't branch/tag-reachable.
  if ! work=$(cd "$w" && jj log --ignore-working-copy --no-graph \
        -r '(::@ ~ ::(bookmarks() | remote_bookmarks() | tags())) & ~empty()' \
        -T '"x"' 2>/dev/null); then
    continue                                 # query failed -> keep (fail-safe)
  fi
  [ -n "$work" ] && continue                 # would abandon work -> keep

  days=$(( idle / 86400 ))
  if [ "$APPLY" = 1 ]; then
    jj -R "$REPO" workspace forget "$n" 2>/dev/null || true
    rm -rf "$w"
    echo "reaped $n (idle ${days}d)"
  else
    echo "would reap $n (idle ${days}d)"
  fi
done

# Phantom sweep: forget any registered workspace whose .jj-worktrees dir is gone.
# No dir => no on-disk work to lose, so this is safe regardless of the gates above.
jj -R "$REPO" workspace list 2>/dev/null | sed 's/:.*//' | while read -r n; do
  [ -n "$n" ] || continue
  [ "$n" = "default" ] && continue
  [ -d "$REPO/.jj-worktrees/$n" ] && continue
  if [ "$APPLY" = 1 ]; then
    jj -R "$REPO" workspace forget "$n" 2>/dev/null && echo "reaped phantom $n (dir missing)"
  else
    echo "would reap phantom $n (dir missing)"
  fi
done
