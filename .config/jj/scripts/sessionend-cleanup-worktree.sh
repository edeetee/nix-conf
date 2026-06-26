#!/bin/bash
# SessionEnd hook: clean-exit cleanup of the jj worktree this session ran in.
#
# Removes the worktree ONLY if it's safe — no uncommitted changes and no local
# commits that aren't already on a remote bookmark or trunk. Anything with
# unsaved/unpushed work is left for the user. Crash/SIGKILL/headless cases never
# fire this hook at all; those are caught by the external reaper.
#
# Must stay synchronous and fast (async SessionEnd hooks get killed mid-run).
set -u

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] || exit 0

# Only act inside a jj worktree under <project>/.jj-worktrees/<name>.
case "$CWD" in
  */.jj-worktrees/*) ;;
  *) exit 0 ;;
esac
[ -d "$CWD/.jj" ] || exit 0

NAME=$(basename "$CWD")
[ "$NAME" = "default" ] && exit 0

cd "$CWD" || exit 0

# Snapshot + safety gate: keep the worktree only if removing it would ABANDON
# work -- i.e. a NON-EMPTY commit in @'s history that no bookmark or tag keeps
# alive. Commits reachable from any branch (local or remote) survive the forget,
# so those are safe to drop. Fail-safe: if the query errors, keep.
if ! WORK=$(jj log --no-graph \
      -r '(::@ ~ ::(bookmarks() | remote_bookmarks() | tags())) & ~empty()' \
      -T '"x"' 2>/dev/null); then
  exit 0
fi
[ -n "$WORK" ] && exit 0

# Safe to drop. Forget from the main repo, then remove the dir.
PROJECT="${CWD%/.jj-worktrees/*}"
jj -R "$PROJECT" workspace forget "$NAME" 2>/dev/null || true
rm -rf "$CWD"
exit 0
