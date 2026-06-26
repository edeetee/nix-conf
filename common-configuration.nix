{ hunk }:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # jj tooling (wrapper + worktree support + behaviour tests). See jj-tools.nix.
  jjTools = import ./jj-tools.nix { inherit pkgs; };
  hunkPkg = hunk.packages.${pkgs.stdenv.hostPlatform.system}.hunk;
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
    jjTools.jj-with-sync
    lazyjj
    jjui
    git-absorb
    hunkPkg
    ripgrep
    uv
    golangci-lint
    fzf
    postgresql
    kdePackages.kdeconnect-kde
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
    		# Source machine-local secrets (not in repo)
    		[ -f "$HOME/dev/nix-conf/darwin/secrets" ] && source "$HOME/dev/nix-conf/darwin/secrets"

    		export GOPATH="$HOME/go"
    		export PATH="$GOPATH/bin:$HOME/.npm-global/bin:$PATH"

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

  programs.direnv.enable = true;

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
