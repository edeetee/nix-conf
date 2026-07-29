# Body of the `jj` wrapper (writeShellScriptBin "jj").
#
# Runs the real jj, then reconciles git's view of the repo so git-native tools
# (Zed's worktree picker, gutters, blame) make sense in colocated jj repos and
# in jj workspaces. Two cases:
#
#   1. Main colocated repo (.git is a directory): promote a detached HEAD to a
#      branch symref when it sits on a bookmark, so editors show a branch name.
#   2. Secondary jj workspace: register it as a real git worktree (so it shows
#      in `git worktree list` -> Zed's picker) and keep its HEAD + index aligned
#      with the workspace's bookmark (so the diff gutter base is correct). A
#      per-worktree pre-commit hook blocks `git commit` there, since git writes
#      desync jj (see _JJ_WT_HOOKS).
#
# nix injects: $_JJ_REAL (real jj binary), $_GIT (git binary), $_JJ_WT_HOOKS
# (hook dir). reconcile only ever calls $_JJ_REAL, never the wrapper, so it does
# not recurse.
#
# This is a hand-rolled stand-in for jj's native colocated-workspace support
# (jj-vcs/jj#8052); remove it once that lands.

"$_JJ_REAL" "$@"
rc=$?

reconcile() {
  local jjroot
  jjroot=$("$_JJ_REAL" workspace root 2>/dev/null) || return 0

  # --- Case 1: main colocated repo ---
  if [ -d "$jjroot/.git" ]; then
    "$_GIT" -C "$jjroot" symbolic-ref -q HEAD >/dev/null && return 0
    local sha bm
    sha=$("$_GIT" -C "$jjroot" rev-parse HEAD 2>/dev/null) || return 0
    bm=$("$_GIT" -C "$jjroot" for-each-ref --format='%(refname:short)' \
        --points-at="$sha" refs/heads/ 2>/dev/null | head -1)
    [ -n "$bm" ] && "$_GIT" -C "$jjroot" symbolic-ref HEAD "refs/heads/$bm" >/dev/null
    return 0
  fi

  # --- Case 2: secondary jj workspace -> git worktree ---
  [ -f "$jjroot/.jj/repo" ] || return 0
  local rel main_store main_root main_git
  rel=$(cat "$jjroot/.jj/repo")                       # path is relative to .jj/
  main_store=$(cd "$jjroot/.jj" && cd "$(dirname "$rel")" 2>/dev/null && pwd) || return 0
  main_root=$(dirname "$main_store"); main_git="$main_root/.git"
  [ -d "$main_git" ] || return 0                      # only when main repo is colocated

  # The workspace's own bookmark: nearest mutable bookmark in @'s ancestry.
  local bm
  bm=$("$_JJ_REAL" -R "$jjroot" log --no-graph \
        -r 'latest(heads(::@ & bookmarks() & mutable()))' \
        -T 'bookmarks' 2>/dev/null | head -1 | sed 's/[ *].*//')
  [ -n "$bm" ] || return 0

  # Don't claim a branch already checked out by the main worktree (e.g. before
  # the workspace has its own bookmark). Defer until it has a distinct one.
  local main_branch
  main_branch=$("$_GIT" -C "$main_root" symbolic-ref -q --short HEAD 2>/dev/null || true)
  [ "$bm" = "$main_branch" ] && return 0

  "$_JJ_REAL" -R "$jjroot" git export >/dev/null 2>&1  # ensure refs/heads/$bm exists
  local name admin
  name=$(basename "$jjroot")
  admin="$main_git/worktrees/$name"

  if [ ! -f "$jjroot/.git" ]; then                    # register once
    mkdir -p "$admin/info"
    printf '%s\n' "$jjroot/.git" > "$admin/gitdir"
    printf '../..\n' > "$admin/commondir"
    printf 'ref: refs/heads/%s\n' "$bm" > "$admin/HEAD"   # HEAD before --worktree config
    printf 'gitdir: %s\n' "$admin" > "$jjroot/.git"
    grep -qxF '.jj' "$main_git/info/exclude" 2>/dev/null || printf '.jj\n' >> "$main_git/info/exclude"
    "$_GIT" -C "$main_root" config extensions.worktreeConfig true
    "$_GIT" -C "$jjroot" config --worktree core.hooksPath "$_JJ_WT_HOOKS"
  fi

  # Keep HEAD + index aligned with the bookmark so the gutter base is correct.
  printf 'ref: refs/heads/%s\n' "$bm" > "$admin/HEAD"
  "$_GIT" -C "$jjroot" read-tree "refs/heads/$bm" 2>/dev/null || true
}

reconcile || true
exit $rc
