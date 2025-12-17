{username, homeDirectory, configDir, karabinerSource ? null}: { config, lib, ... }:

{
  home.username = lib.mkForce username;
  home.homeDirectory = lib.mkForce homeDirectory;
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  home.file.".hushlogin".text = "";

  home.file.".gitconfig".source = ./.gitconfig;

  home.file.".config/kitty".source = ./kitty;

  # home.file.".config/karabiner/karabiner.json" = lib.mkIf (karabinerSource != null) {
  #   source = karabinerSource;
  # };

  home.file."Library/Services/ghostty_finder.workflow".source = ./ghostty_finder.workflow;

  home.file.".config/ghostty/config".source = ./ghostty/config;

  # home.file."Library/Preferences/eu.exelban.Stats.plist".source = ./Stats.plist;
}