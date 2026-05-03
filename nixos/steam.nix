{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin # Community Proton build with better game compatibility
    ];
  };

  programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        ## Put here any library that is required when running a package
        ## ...
        ## Uncomment if you want to use the libraries provided by default in the steam distribution
        ## but this is quite far from being exhaustive
        ## https://github.com/NixOS/nixpkgs/issues/354513
        (pkgs.runCommand "steamrun-lib" {} "mkdir $out; ln -s ${pkgs.steam-run.fhsenv}/usr/lib64 $out/lib")
      ];
    };

  ## start steam in gamepad mode when the mode button is pressed on the controller
  services.triggerhappy = {
    enable = true;
    user = "root";
    extraConfig = ''
      # Start Steam in Gamepad Mode when the mode button is pressed on the controller
      BTN_MODE 1 systemctl --machine=edeetee@.host --user start steam-on-demand.service
    '';
  };

  systemd.user.services.steam-on-demand = {
    enable = true;
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.steam} -gamepadui";
      User = "edeetee";
      Environment = "DISPLAY=:0";
    };
  };
}
