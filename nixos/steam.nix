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
