{username, homeDirectory, configDir, karabinerSource ? null, gitEmail ? null, hammerspoon ? false}: { config, lib, pkgs, ... }:

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

  # Put every repo in ~/dev on zoxide's radar without letting it outrank a real
  # visit: rank 1 with a 1970 timestamp is the lowest frecency tier. Skips paths
  # already in the database, because importing sums ranks.
  home.activation.seedZoxideDev = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -d "${homeDirectory}/dev" ]; then
      seed=$(mktemp)
      comm -23 \
        <(find "${homeDirectory}/dev" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort) \
        <(${pkgs.zoxide}/bin/zoxide query -l | sort) \
        | sed 's/$/|1|0/' > "$seed"
      if [ -s "$seed" ]; then
        $DRY_RUN_CMD ${pkgs.zoxide}/bin/zoxide import --from=z --merge "$seed"
      fi
      rm -f "$seed"
    fi
  '';

  home.file = configSymlinks // lib.optionalAttrs hammerspoon {
    # Out-of-store symlinks so edits apply live, no rebuild
    ".hammerspoon/init.lua".source =
      config.lib.file.mkOutOfStoreSymlink "${nixConfDir}/darwin/hammerspoon/init.lua";
    # Add this directory once in Raycast: Settings → Extensions → + → Add Script Directory
    ".config/raycast-scripts".source =
      config.lib.file.mkOutOfStoreSymlink "${nixConfDir}/darwin/raycast-scripts";
  } // {
    ".hushlogin".text = "";

    ".gitconfig" = if gitEmail != null then {
      text =
        let gitconfigContent = builtins.readFile ./.gitconfig;
        in lib.replaceStrings
          ["email = dev@edt.nz"]
          ["email = ${gitEmail}"]
          gitconfigContent;
    } else {
      source = ./.gitconfig;
    };

    # home.file.".config/karabiner/karabiner.json" = lib.mkIf (karabinerSource != null) {
    #   source = karabinerSource;
    # };

    # Out-of-store symlink so pi can write packages back to the file
    ".pi/agent" = {
      source = config.lib.file.mkOutOfStoreSymlink "${configDir}/pi-agent";
      recursive = true;
    };

    "Library/Services/ghostty_finder.workflow".source = ./ghostty_finder.workflow;

    # home.file."Library/Preferences/eu.exelban.Stats.plist".source = ./Stats.plist;
  };
}