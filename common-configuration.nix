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
    zoxide
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
      eval "$(${pkgs.zoxide}/bin/zoxide init zsh)"

      # Ghost-suggest the directory name `z <query>` resolves to, so right-arrow
      # completes a jump never typed in full. The name, never the resolved path:
      # accepting appends the ghost text to the buffer verbatim.
      _zsh_autosuggest_strategy_zoxide() {
        [[ $1 == z' '[^-./~]* ]] || return
        local query=''${1#z } dir
        dir=$(${pkgs.zoxide}/bin/zoxide query --exclude "$PWD" -- ''${(z)query} 2>/dev/null) || return
        [[ ''${dir:t} == "$query"* ]] && typeset -g suggestion="z ''${dir:t}"
      }
      ZSH_AUTOSUGGEST_STRATEGY=(zoxide history)

      # Trail the resolved path, dimmed, after the ghost text. POSTDISPLAY is the
      # only place ZLE renders text past the cursor, and it belongs to the
      # autosuggest plugin, which appends all of it to the buffer on accept —
      # hence the wrapper below, which drops the trail before the plugin sees it.
      autoload -Uz add-zle-hook-widget
      _zoxide_trail() {
        (( $+_zoxide_trail_wrapped )) || { typeset -g _zoxide_trail_wrapped=1; _zoxide_trail_wrap }
        _zoxide_trail_drop

        local query="" dir=""
        [[ $BUFFER == z' '[^-./~]* ]] && query=''${BUFFER#* }
        [[ -n $query ]] && dir=$(${pkgs.zoxide}/bin/zoxide query --exclude "$PWD" -- ''${(z)query} 2>/dev/null)
        [[ -n $dir ]] || return

        typeset -g _zoxide_trail_text="  ''${dir/#$HOME/~}"
        typeset -g _zoxide_trail_hl="$(($#BUFFER + $#POSTDISPLAY)) $(($#BUFFER + $#POSTDISPLAY + $#_zoxide_trail_text)) fg=242"
        POSTDISPLAY+=$_zoxide_trail_text
        region_highlight+=($_zoxide_trail_hl)
      }

      # Accepting a suggestion must not type the trail into the command line.
      _zoxide_trail_drop() {
        [[ -n $_zoxide_trail_text ]] || return
        POSTDISPLAY=''${POSTDISPLAY%"$_zoxide_trail_text"}
        region_highlight=("''${(@)region_highlight:#$_zoxide_trail_hl}")
        _zoxide_trail_text="" _zoxide_trail_hl=""
      }

      _zoxide_trail_wrap() {
        local w
        for w in $ZSH_AUTOSUGGEST_ACCEPT_WIDGETS $ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS; do
          [[ $widgets[$w] == user:* ]] || continue
          zle -N "_zoxide_trail_inner_$w" "''${widgets[$w]#*:}"
          functions[_zoxide_trail_outer_$w]='_zoxide_trail_drop; zle _zoxide_trail_inner_'$w' -- "$@"'
          zle -N "$w" "_zoxide_trail_outer_$w"
        done
      }

      add-zle-hook-widget zle-line-init _zoxide_trail_drop
      add-zle-hook-widget zle-line-pre-redraw _zoxide_trail

      # Async suggestions land from an fd handler, which never runs
      # zle-line-pre-redraw — it would wipe the trail milliseconds after every
      # keystroke. Sync mode keeps both writers of POSTDISPLAY ordered. Deferred
      # to the first precmd because the plugin is sourced after this file.
      autoload -Uz add-zsh-hook
      _zoxide_trail_sync() {
        unset ZSH_AUTOSUGGEST_USE_ASYNC
        add-zsh-hook -d precmd _zoxide_trail_sync
      }
      add-zsh-hook precmd _zoxide_trail_sync

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
