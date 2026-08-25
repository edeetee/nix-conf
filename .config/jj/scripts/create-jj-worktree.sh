#!/bin/bash
set -e

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')

WORKTREE_PATH="$CLAUDE_PROJECT_DIR/.jj-worktrees/$NAME"
mkdir -p "$WORKTREE_PATH"

cd "$CLAUDE_PROJECT_DIR"
jj workspace add "$WORKTREE_PATH" >&2

# A jj workspace has no .git, so git resolves to the main checkout and EnterWorktree refuses it.
# Register it as a git worktree: create one elsewhere, move its .git file in, repair the back-pointer.
SHIM="$(mktemp -d)/$NAME"
git worktree add --no-checkout --detach "$SHIM" "$(jj -R "$WORKTREE_PATH" log -r @- --no-graph -T commit_id)" >&2
mv "$SHIM/.git" "$WORKTREE_PATH/.git"
rm -rf "$(dirname "$SHIM")"
git -C "$WORKTREE_PATH" worktree repair >&2
git -C "$WORKTREE_PATH" reset -q >&2

echo "$WORKTREE_PATH"
