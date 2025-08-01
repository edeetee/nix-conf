{username, homeDirectory}: { config, lib, ... }:

{
  home.username = lib.mkForce username;
  home.homeDirectory = lib.mkForce homeDirectory;
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  home.file.".hushlogin".text = "";

  home.file.".gitconfig".source = config.lib.file.mkOutOfStoreSymlink ./.gitconfig;

  home.file.".config/kitty".source = config.lib.file.mkOutOfStoreSymlink ./kitty;

  home.file.".config/karabiner/karabiner.json".source = config.lib.file.mkOutOfStoreSymlink ./karabiner.json;

  home.file."Library/Services/Kitty Finder.workflow".source = config.lib.file.mkOutOfStoreSymlink ./kitty_finder.workflow;

  home.file."Library/Preferences/eu.exelban.Stats.plist".source = config.lib.file.mkOutOfStoreSymlink ./Stats.plist;

  # home.file.".config/kitty/current-theme.conf".text = ''
  #   # Tokyo Night theme
  #   background #1a1b26
  #   foreground #c0caf5
  #   selection_background #33467c
  #   selection_foreground #c0caf5
  #   url_color #73daca
  #   cursor #c0caf5
  #   cursor_text_color #1a1b26

  #   # Tabs
  #   active_tab_background #7aa2f7
  #   active_tab_foreground #16161e
  #   inactive_tab_background #292e42
  #   inactive_tab_foreground #545c7e
  #   tab_bar_background #15161e

  #   # Normal colors
  #   color0 #15161e
  #   color1 #f7768e
  #   color2 #9ece6a
  #   color3 #e0af68
  #   color4 #7aa2f7
  #   color5 #bb9af7
  #   color6 #7dcfff
  #   color7 #a9b1d6

  #   # Bright colors
  #   color8 #414868
  #   color9 #f7768e
  #   color10 #9ece6a
  #   color11 #e0af68
  #   color12 #7aa2f7
  #   color13 #bb9af7
  #   color14 #7dcfff
  #   color15 #c0caf5
  # '';
}