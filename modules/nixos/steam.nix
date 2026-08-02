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
    package = pkgs.steam.override {
      # pressure-vessel creates POSIX symlinks in its var/tmp dirs, which fails on
      # NTFS (Steam library on /mnt/hdd). Redirect to /tmp which is on tmpfs.
      extraEnv = {
        PRESSURE_VESSEL_VARIABLE_DIR = "/tmp/pressure-vessel";
      };
    };
  };
  programs.gamemode.enable = true;

  # Workaround for nixpkgs#354513: steam-run libs missing from nix-ld context,
  # causing pressure-vessel architecture detection and wine DLL failures.
  programs.nix-ld.libraries = with pkgs; [
    (pkgs.runCommand "steamrun-lib" { } "mkdir $out; ln -s ${pkgs.steam-run.fhsenv}/usr/lib64 $out/lib")
  ];

  ## Start Steam in gamepad mode when a controller is connected or the home button is pressed
  # udev: auto-start when any game controller is plugged in / connected
  services.udev.extraRules = ''
    ACTION=="add", ENV{ID_INPUT_JOYSTICK}=="1", \
      RUN+="${pkgs.systemd}/bin/systemctl --no-block --machine=edeetee@.host --user start steam-on-demand.service"
  '';

  # triggerhappy: fallback — press the home (mode) button to start Steam
  services.triggerhappy = {
    enable = true;
    user = "root";
    extraConfig = ''
      BTN_MODE 1 systemctl --machine=edeetee@.host --user start steam-on-demand.service
    '';
  };

  systemd.user.services.steam-on-demand = {
    enable = true;
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.steam} -gamepadui";
      User = "edeetee";
      Environment = ["DISPLAY=:0" "PULSE_LATENCY_MSEC=60"];
    };
  };
}
