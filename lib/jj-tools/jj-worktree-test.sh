set -eu

# Behaviour test for the jj-with-sync wrapper, run as a nix build (sandboxed).
# Drives the *wrapper* (jj on PATH) through a colocated repo + a jj workspace
# and asserts that git's view ends up correct. `git`/wrapper write to a temp
# tree; success touches $out.

export HOME="$TMPDIR/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email "test@example.com"
git config --global user.name "Test"
git config --global init.defaultBranch main
export JJ_CONFIG="$HOME/jj.toml"
printf '[user]\nname = "Test"\nemail = "test@example.com"\n' > "$JJ_CONFIG"

fail() { echo "FAIL: $1" >&2; exit 1; }

root="$TMPDIR/work"
main="$root/main"
ws="$root/feat"
mkdir -p "$main"; cd "$main"

# --- main colocated repo with history ---
jj git init --colocate
printf 'alpha\nbeta\n' > app.txt
jj describe -m init
jj bookmark create main -r @
jj new -m gamma
printf 'alpha\nbeta\ngamma\n' > app.txt
jj bookmark set main -r @ --allow-backwards
jj new main -m wip

# --- workspace, driven entirely through the wrapper ---
jj workspace add "$ws" --name feat
cd "$ws"
jj new main -m "feat work"
printf 'alpha\nbeta\ngamma\ndelta\n' > app.txt
jj commit -m "feat: add delta"
jj bookmark create feat-branch -r @-
printf 'alpha\nbeta\ngamma\ndelta\nEPSILON\n' > app.txt
jj status            # triggers reconcile

# --- assertions ---
git -C "$main" worktree list --porcelain | grep -q "branch refs/heads/feat-branch" \
  || fail "workspace not registered as a git worktree on feat-branch"

[ "$(git -C "$ws" rev-parse --abbrev-ref HEAD)" = "feat-branch" ] \
  || fail "worktree HEAD is not feat-branch"

# gutter base correct: only the uncommitted EPSILON line shows as modified
git -C "$ws" --no-optional-locks status --short | grep -qE '^ ?M +app.txt' \
  || fail "worktree shows wrong/no diff (index base not synced to bookmark)"

# git commit inside the worktree must be blocked
git -C "$ws" add -A
if git -C "$ws" commit -m "should be blocked" >/dev/null 2>&1; then
  fail "git commit in worktree was NOT blocked"
fi

# git commit in the main repo must still work (hook is worktree-scoped)
printf 'zeta\n' >> "$main/app.txt"
git -C "$main" add -A
git -C "$main" -c commit.gpgsign=false commit -m "main ok" >/dev/null 2>&1 \
  || fail "git commit in main repo was wrongly blocked"

# idempotency: a second reconcile must not add a duplicate worktree
cd "$ws"; jj status
[ "$(git -C "$main" worktree list | wc -l | tr -d ' ')" = "2" ] \
  || fail "reconcile registered a duplicate worktree"

echo "all jj-worktree behaviour checks passed"
touch "$out"
