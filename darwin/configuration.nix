{ user, self, homebrew-core, homebrew-cask, nixvim-vsc }:
{ pkgs, lib, ... }:
let
  homebrewTaps = {
    "homebrew/homebrew-core" = homebrew-core;
    "homebrew/homebrew-cask" = homebrew-cask;
  };
in
{
  environment.variables.EDITOR = "nvim";
  environment.variables.DOCKER_DEFAULT_PLATFORM = "linux/amd64";

  nix-homebrew = {
    enable = true;
    user = user;
    taps = homebrewTaps;
    autoMigrate = true;
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nvim-vsc" "exec -a $0 ${
      nixvim-vsc.packages.${pkgs.stdenv.hostPlatform.system}.default
    }/bin/nvim $@")
  ];

  homebrew = {
    enable = true;
    onActivation = { };
    taps = builtins.attrNames homebrewTaps;
    brews = [
      "yt-dlp"
      "gh"
      "ffmpeg"
      "nvm"
      "colima"
      "cloud-sql-proxy"
      "kubectl"
      "direnv"
    ];
    casks = [
      "karabiner-elements"
      "kitty"
      "hot"
      "stats"
      "raycast"
      "ghostty"
      "monitorcontrol"
      "visual-studio-code"
      "obsidian"
      "eqmac"
      "altair-graphql-client"
    ];
  };

  security.pam.services.sudo_local.touchIdAuth = true;

  environment.shellAliases = {
    nixrs = "sudo darwin-rebuild switch --flake ~/dev/nix-conf/";
    nixe = "v ~/dev/nix-conf/";
    nixcd = "cd ~/dev/nix-conf/";
    "'?'" = "gh copilot";
  };

  programs.zsh = {
    enableSyntaxHighlighting = true;
    enableFzfCompletion = true;
    enableFzfHistory = true;
  };

  nix.enable = false;

  nix.extraOptions = ''
    extra-platforms = x86_64-darwin aarch64-darwin
  '';

  system.defaults = {
    NSGlobalDomain = {
      ApplePressAndHoldEnabled = false;
      AppleScrollerPagingBehavior = true;
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      InitialKeyRepeat = 10;
      KeyRepeat = 2;
      NSWindowResizeTime = .05;
    };

    finder = {
      FXDefaultSearchScope = "SCcf";
      FXEnableExtensionChangeWarning = false;
      FXPreferredViewStyle = "clmv";
      FXRemoveOldTrashItems = true;
      NewWindowTarget = "Other";
      NewWindowTargetPath = "file:///Users/edeetee/dev";
    };

    dock = {
      autohide = true;
      mru-spaces = false;
      appswitcher-all-displays = true;
    };
  };

  system.configurationRevision = self.rev or self.dirtyRev or null;
  system.stateVersion = 4;
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.primaryUser = user;
}
