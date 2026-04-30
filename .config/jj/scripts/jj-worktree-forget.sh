#!/usr/bin/env bash
# Forget the jj worktree(s) whose working copy is the given change.
# Usage: jj-worktree-forget.sh <change_id>
# Skips the `default` workspace.
set -euo pipefail

change_id="${1:?change_id required}"

matches=$(jj workspace list | awk -v cid="$change_id" '
  {
    name = $1; sub(/:$/, "", name)
    ws_cid = $2
    if (index(cid, ws_cid) == 1 || index(ws_cid, cid) == 1) {
      print name
    }
  }
')

if [ -z "$matches" ]; then
  echo "No worktree at change $change_id"
  exit 0
fi

# Filter out `default` — never forget it.
candidates=()
while IFS= read -r name; do
  [ -z "$name" ] && continue
  [ "$name" = "default" ] && continue
  candidates+=("$name")
done <<< "$matches"

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "Only the default workspace is at $change_id — nothing to do"
  exit 0
fi

# If multiple, let the user pick. Pick all with `*`.
if [ "${#candidates[@]}" -gt 1 ]; then
  echo "Multiple worktrees at $change_id:"
  if command -v fzf >/dev/null 2>&1; then
    selected=$(printf '%s\n' "${candidates[@]}" | fzf --multi --prompt="forget> " --header="tab=mark, enter=confirm")
    [ -z "$selected" ] && { echo "cancelled"; exit 0; }
    chosen=()
    while IFS= read -r line; do chosen+=("$line"); done <<< "$selected"
  else
    PS3="forget which? (number, or 'a' for all, 'q' to quit) "
    select pick in "${candidates[@]}" "all" "quit"; do
      case "$pick" in
        all) chosen=("${candidates[@]}"); break ;;
        quit|"") echo "cancelled"; exit 0 ;;
        *) chosen=("$pick"); break ;;
      esac
    done
  fi
else
  chosen=("${candidates[0]}")
fi

repo_root=$(jj workspace root)

for name in "${chosen[@]}"; do
  echo "Forgetting worktree: $name"
  jj workspace forget "$name"
  rm -rf "$repo_root/.jj-worktrees/$name"
done
