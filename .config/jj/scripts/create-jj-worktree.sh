#!/bin/bash
set -e

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')

WORKTREE_PATH="$CLAUDE_PROJECT_DIR/.jj-worktrees/$NAME"
mkdir -p "$WORKTREE_PATH"

cd "$CLAUDE_PROJECT_DIR"
jj workspace add "$WORKTREE_PATH" >&2

echo "$WORKTREE_PATH"
