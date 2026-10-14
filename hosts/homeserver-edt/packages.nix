# System packages and fonts for homeserver-edt
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    sops
    vim
    wget
    git
    rocmPackages.rocm-smi
    nvtopPackages.amd
    pkgsRocm.blender
    jellyfin-desktop
    kdePackages.kdeconnect-kde
    vlc
  ];

  fonts = {
    packages = with pkgs; [ julia-mono ];
    fontconfig.defaultFonts = {
      monospace = [ "Julia Mono" ];
    };
  };

  # Shell aliases local to this machine
  environment.shellAliases = {
    nixrs = "sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
    nixup = "git -C ~/dev/nix-conf pull --quiet && git -C ~/dev/nix-conf --no-pager log --oneline ..@{u} 2>/dev/null && sudo nixos-rebuild switch --flake ~/dev/nix-conf/";
  };

  users.users.edeetee = {
    isNormalUser = true;
    # Pinned deliberately. Without this NixOS allocates the uid dynamically,
    # and several things here assume it is 1000: /run/user/1000 in AGENTS.md
    # and AIRPLAY.md, and the `uid=` option of the Mac share mount
    # (mac-share.nix, which cannot guess a dynamically allocated uid).
    # Verified on the host: `id -u edeetee` -> 1000.
    uid = 1000;
    extraGroups = [
      "wheel"
      "video"
      "networkmanager"
      "render"
    ];
    packages = with pkgs; [ ];
  };

  users.defaultUserShell = pkgs.zsh;

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    plugins = [
      pkgs.tmuxPlugins.catppuccin
      pkgs.tmuxPlugins.continuum
    ];
  };

  programs.zsh = {
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
  };

  programs.nixvim.defaultEditor = true;
}
