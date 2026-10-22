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
    pkgs.nixos-rebuild
    (pkgs.writeShellScriptBin "nvim-vsc" "exec -a $0 ${
      nixvim-vsc.packages.${pkgs.stdenv.hostPlatform.system}.default
    }/bin/nvim $@")
    # transmission-remote, to drive the homeserver's torrent daemon
    # (services.transmission in hosts/homeserver-edt/services.nix: RPC on 9091,
    # no auth, whitelist disabled). Deliberately nixpkgs rather than a brew:
    # this is transmission 4.1.3, the same version the daemon runs, and the v3
    # and v4 RPC are not interchangeable. It is cached for aarch64-darwin, so
    # there is nothing to build and activation is instant.
    pkgs.transmission_4
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
      "cmux"
    ];
  };

  security.pam.services.sudo_local.touchIdAuth = true;

  environment.shellAliases = {
    # pi against the local Qwen on homeserver-edt. The wrapper exists because the
    # prompt is a real cost on a 32k window: stock pi sends ~9.3k tokens of
    # system prompt and tool catalogue, this sends ~3.9k (measured, see
    # plans/local-qwen.md §4.1).
    piq = "/Users/edeetee/dev/nix-conf/darwin/pi-agent/piq.sh";
    nixrs = "sudo darwin-rebuild switch --flake ~/dev/nix-conf/";
    nixe = "v ~/dev/nix-conf/";
    nixcd = "cd ~/dev/nix-conf/";
    "'?'" = "gh copilot";
    # Deploy to the homeserver via nixos-rebuild's built-in remote mode.
    # --ask-sudo-password prompts locally once and pipes it to remote sudo
    # over stdin, so no permanent NOPASSWD rule is needed.
    #
    # --build-host is not optional: without it nixos-rebuild builds *here*, and
    # this Mac is aarch64-darwin with no x86_64-linux builder (no
    # /etc/nix/machines, and nix.linux-builder is disabled), so the build fails.
    # With it, the server builds and switches — the same work `nixup` does there.
    push-server = "nixos-rebuild switch --flake ~/dev/nix-conf#homeserver-edt --build-host edeetee@homeserver-edt.local --target-host homeserver-edt.local --ask-sudo-password";
    # The same deploy without a password prompt: pushes, pulls on the server as
    # edeetee, pre-flights the sops secrets, then runs the NOPASSWD'd
    # `nixos-deploy` (hosts/homeserver-edt/deploy.nix). This is the one that
    # works from scripts and agents.
    deploy-server = "~/dev/nix-conf/scripts/deploy-server.sh";
    # Drive the homeserver's torrent daemon from here: `torrents -l`,
    # `torrents -a file.torrent`, `torrents -t all -s`. Drop this if you would
    # rather type the host out each time.
    torrents = "transmission-remote homeserver-edt.local:9091";
  };

  programs.zsh = {
    enableSyntaxHighlighting = true;
    enableAutosuggestions = true;
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

  # Power management: this machine hosts the personal agent harness, so it
  # must stay awake whenever it's plugged in — including with the lid closed
  # (disablesleep 1 only applies on AC). On battery it sleeps normally, so
  # it's safe to close and bag it. Applied on every darwin-rebuild.
  system.activationScripts.power.text = ''
    # AC: never auto-sleep; keep running with the lid closed (clamshell)
    pmset -c sleep 0
    pmset -c disablesleep 1
    pmset -c displaysleep 10
    # Battery: normal laptop behavior — sleeps with the lid, saves battery
    pmset -b sleep 10
    pmset -b displaysleep 5
  '';

  system.configurationRevision = self.rev or self.dirtyRev or null;
  system.stateVersion = 4;
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.primaryUser = user;
}
