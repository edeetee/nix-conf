# jj tooling, split out of common-configuration.nix.
#
# Provides a `jj` wrapper that reconciles git's view of colocated repos and jj
# workspaces so git-native editors (Zed) see real branches and worktrees, plus
# a behaviour test exposed as a flake check. See jj-sync.sh for the logic.
#
# Usage:
#   let jjTools = import ./lib/jj-tools { inherit pkgs; };
#   in  environment.systemPackages = [ jjTools.jj-with-sync ];
#   and flake checks: jjTools.checks.jj-worktree-test

{ pkgs }:
let
  # Hook dir whose pre-commit rejects `git commit` inside a jj worktree, since
  # git writes there desync jj. Lives in the nix store; the wrapper points each
  # worktree's core.hooksPath at this path.
  worktreeHooks = pkgs.runCommand "jj-worktree-hooks" { } ''
    mkdir -p "$out"
    install -m755 ${pkgs.writeShellScript "pre-commit" ''
      echo "✋ This is a jj-managed worktree. Commit with jj, not git." >&2
      exit 1
    ''} "$out/pre-commit"
  '';

  # The `jj` wrapper. A small nix-generated preamble injects store paths as env
  # vars, then the (un-escaped, lintable) bash body is read in verbatim.
  jj-with-sync = pkgs.writeShellScriptBin "jj" ''
    export _JJ_REAL=${pkgs.jujutsu}/bin/jj
    export _GIT=${pkgs.git}/bin/git
    export _JJ_WT_HOOKS=${worktreeHooks}
    ${builtins.readFile ./jj-sync.sh}
  '';

  # Behaviour test: drives the wrapper through a colocated repo + a workspace
  # and asserts git's view ends up correct. `jj` on PATH is the wrapper.
  jj-worktree-test = pkgs.runCommand "jj-worktree-test"
    {
      nativeBuildInputs = [
        jj-with-sync
        pkgs.git
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ];
    }
    (builtins.readFile ./jj-worktree-test.sh);
in
{
  inherit jj-with-sync worktreeHooks;
  checks = { inherit jj-worktree-test; };
}
