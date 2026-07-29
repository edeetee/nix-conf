# Desktop / display / audio / bluetooth for homeserver-edt
{ pkgs, ... }:
{
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "edeetee";
    };
    sddm.enable = true;
  };

  services.desktopManager.plasma6.enable = true;

  # Bluetooth — needed for DualShock controllers
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Force Bluetooth adapter power on after KDE login (KDE/Bluedevil can save a
  # powered-off state at shutdown).
  systemd.user.services.bt-power-on = {
    description = "Force Bluetooth power on after KDE login";
    after = [ "plasma-plasmashell.service" ];
    wantedBy = [ "plasma-plasmashell.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bluez}/bin/btmgmt power on";
      RemainAfterExit = true;
    };
  };

  # Enable wake for all Bluetooth USB controllers
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="e0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
  '';

  security.rtkit.enable = true;
}
