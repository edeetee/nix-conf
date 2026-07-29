# System packages and fonts for homeserver-edt
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    rocmPackages.rocm-smi
    nvtopPackages.amd
    pkgsRocm.blender
    jellyfin-desktop
    kdePackages.kdeconnect-kde
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
