#!/bin/bash
# jj-orient.sh — SessionStart orientation line.
#
# Prints where the session actually is: worktree vs main repo, cwd, and the
# current @ (change id, empty flag, bookmark). Guards against the trap where a
# resumed/compacted session lands back in the primary dir — NOT the worktree it
# was created in — while file edits (absolute paths) keep hitting the worktree.
# That split silently desyncs jj commands from the files being edited.
#
# Uses --ignore-working-copy so it never snapshots (no op-log churn / forks).
set -u

ws=$(jj workspace root 2>/dev/null) || exit 0   # not a jj repo -> stay silent

case "$ws" in
  *"/.jj-worktrees/"*) loc="worktree ${ws##*/.jj-worktrees/}" ;;
  *)                   loc="MAIN REPO (not a worktree)" ;;
esac

at=$(jj log -r @ --no-graph --ignore-working-copy \
  -T 'change_id.short() ++ if(empty, " empty", "") ++ if(local_bookmarks, " " ++ local_bookmarks.join(","), " no-bookmark")' \
  2>/dev/null)

printf 'jj orientation — %s | cwd: %s | @: %s\n' "$loc" "$PWD" "$at"
