{  }:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Wraps `jj` so that after every invocation, if git's HEAD is detached at a
  # commit that has a local bookmark, we promote HEAD to a symbolic ref on
  # that branch. This lets editors (Zed) and git-native tools see a real
  # branch name in colocated jj repos. Lives at the binary level (not as a
  # shell function) so subprocess invocations (jjui, lazyjj, editor
  # extensions) are also covered.
  jj-with-sync = pkgs.writeShellScriptBin "jj" ''
    ${pkgs.jujutsu}/bin/jj "$@"
    rc=$?
    # Only act in colocated jj repos.
    [ -d .git ] && [ -d .jj ] || exit $rc
    # If HEAD is already a symbolic ref, jj didn't detach it — nothing to do.
    ${pkgs.git}/bin/git symbolic-ref -q HEAD >/dev/null && exit $rc
    sha=$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null) || exit $rc
    # Local bookmarks export to refs/heads/ in colocated repos, so we can
    # find a candidate via git rather than spawning jj a second time.
    bm=$(${pkgs.git}/bin/git for-each-ref --format='%(refname:short)' \
        --points-at="$sha" refs/heads/ 2>/dev/null | head -1)
    if [ -n "$bm" ]; then
      ${pkgs.git}/bin/git symbolic-ref HEAD "refs/heads/$bm" >/dev/null
    fi
    exit $rc
  '';
in
{
  # SHELL CONFIGURATION
  environment.systemPackages = with pkgs; [
    nixfmt-classic
    nil
    nixd
    nodejs
    bun
    git-lfs
    docker-compose
    docker
    yarn
    go
    jj-with-sync
    lazyjj
    jjui
    git-absorb
    ripgrep
    uv
    golangci-lint
    fzf
    postgresql
    # workmux.packages.${pkgs.system}.default
    nixd
  ];

  programs.nix-index-database.comma.enable = true;

  fonts.packages = with pkgs; [
    julia-mono
  ];

  environment.shellAliases = {
    l = "${pkgs.eza}/bin/eza --icons";
    ll = "l -l";
    v = "nvim";
    gemcli = "npx https://github.com/google-gemini/gemini-cli";
    gcam = "git commit -a -m";
    gp = "git push";
    gpf = "git push --force-with-lease";
    gpnv = "git push --no-verify";
    gpfnv = "git push --force-with-lease --no-verify";
    stack-pr = "uv tool run stack-pr";
  };

  environment.interactiveShellInit = ''
    		export GOPATH="$HOME/go"
    		export PATH="$GOPATH/bin:$PATH"

    		function gop() {
    			git push origin "HEAD:$1"
    		}

    		function gopf() {
    			git push --force-with-lease origin "HEAD:$1"
    		}

    		function gopnv() {
    			git push --no-verify origin "HEAD:$1"
    		}

    		function gopfnv() {
    			git push --force-with-lease --no-verify origin "HEAD:$1"
    		}
    	'';

  programs.nix-index.enable = true;

  programs.direnv.enable = pkgs.stdenv.isLinux; # TODO: re-enable after nixpkgs includes NixOS/nixpkgs#502769

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    promptInit = ''
      autoload -Uz compinit
      compinit

      source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh

      eval "$(${pkgs.starship}/bin/starship init zsh)"
      PATH="$HOME/.cargo/bin:$PATH"
      source <(COMPLETE=zsh jj)

      # comma command-not-found handler
      command_not_found_handler() {
        comma "$@"
      }
    '';
  };

  # NIX CONFIGURATION
  # nix.settings = {
  #   substituters = [
  #     "http://binarycache.example.com"
  #     "https://nix-community.cachix.org"
  #     "https://cache.nixos.org/"
  #   ];
  #   trusted-public-keys = [
  #     "binarycache.example.com-1:dsafdafDFW123fdasfa123124FADSAD"
  #     "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  #   ];
  # };

  # nix.settings.auto-optimise-store = true;

  nixpkgs.config.allowUnfree = true;
}
