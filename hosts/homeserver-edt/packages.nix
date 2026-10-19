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
    # mpv sits next to VLC for exactly the files VLC mangles: AC-3/DTS (e.g.
    # "DD5.1" releases). VLC bitstreams those instead of decoding, and a
    # bitstream can only be placed on the sink that advertises AC-3 — the HDMI
    # one — so VLC ignores the default sink even when that is the 3.5mm analog
    # output, and its HDMI passthrough then fails outright ("too low audio
    # sample frequency (0)"). mpv decodes to PCM and follows the default sink,
    # so it plays through whatever is currently selected.
    mpv
    vlc
    # Speaks the same MPRIS interface that mpv-mpris exposes (unified-remote.nix):
    # the CLI that proves the plugin loaded, and what a KDE Connect run command
    # would call to pause/play mpv from the phone. See TV-MEDIA.md.
    playerctl
  ];

  # Firefox: a real browser in the TV session. Plasma's own options (Konqueror
  # is not installed, Falkon is a toy) are no use from the couch, and the web
  # players — Jellyfin, YouTube, a streaming site — are the usual reason to want
  # one here. Declared as `programs.firefox` rather than a bare package so the
  # standard NixOS wrapper and /etc/firefox policy files come with it, and so
  # `firefox` is on PATH for every user rather than one profile.
  #
  # No DRM: Widevine cannot be built into nixpkgs' firefox (it is a licensed
  # blob), so Netflix-style sites will refuse to play here. Playing Mac media
  # is what TV-MEDIA.md is for.
  programs.firefox.enable = true;

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
