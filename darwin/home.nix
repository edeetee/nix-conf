{username, homeDirectory, configDir, karabinerSource ? null, gitEmail}: { config, lib, ... }:

let
  nixConfDir = "${homeDirectory}/dev/nix-conf";

  # Auto-symlink each directory in .config/ to the nix-conf repo
  managedConfigs = builtins.readDir ../.config;
  configDirs = lib.filterAttrs (_: type: type == "directory") managedConfigs;
  configSymlinks = lib.mapAttrs' (name: _: lib.nameValuePair
    ".config/${name}"
    { source = config.lib.file.mkOutOfStoreSymlink "${nixConfDir}/.config/${name}"; }
  ) configDirs;
in
{
  home.username = lib.mkForce username;
  home.homeDirectory = lib.mkForce homeDirectory;
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  home.activation.checkNixConfRepo = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    if [ ! -d "${nixConfDir}" ]; then
      echo "ERROR: nix-conf repo not found at ${nixConfDir}" >&2
      echo "Clone it first, or update the path." >&2
      exit 1
    fi
  '';

  home.file = configSymlinks // {
    ".hushlogin".text = "";

    ".gitconfig".text =
      let gitconfigContent = builtins.readFile ./.gitconfig;
      in lib.replaceStrings
        ["email = dev@edt.nz"]
        ["email = ${gitEmail}"]
        gitconfigContent;

    # home.file.".config/karabiner/karabiner.json" = lib.mkIf (karabinerSource != null) {
    #   source = karabinerSource;
    # };

    "Library/Services/ghostty_finder.workflow".source = ./ghostty_finder.workflow;

    # home.file."Library/Preferences/eu.exelban.Stats.plist".source = ./Stats.plist;
  };
}