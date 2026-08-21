# Minimal packages and users for rpi3b
#
# Intentionally tiny. `pi` itself is installed by pi-agent.nix via npm
# (needs nodejs, which the service pulls in via its `path`).

{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    zsh
  ];

  users.users.edeetee = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  users.defaultUserShell = pkgs.zsh;

  programs.zsh.enable = true;

  # npm global bin for the pi install (also in the interactive shell of the
  # homeserver via common.nix — here it's local to this machine)
  environment.interactiveShellInit = ''
    export PATH="$HOME/.npm-global/bin:$PATH"
  '';
}
