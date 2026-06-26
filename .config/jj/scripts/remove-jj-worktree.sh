#!/bin/bash
INPUT=$(cat)
WORKTREE_PATH=$(echo "$INPUT" | jq -r '.worktree_path')
WORKSPACE_NAME=$(basename "$WORKTREE_PATH")

if [ -d "$WORKTREE_PATH" ]; then
  jj -R "$CLAUDE_PROJECT_DIR" workspace forget "$WORKSPACE_NAME" 2>/dev/null || true
  rm -rf "$WORKTREE_PATH"
fi
