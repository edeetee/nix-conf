# Boot configuration for homeserver-edt
{ config, pkgs, ... }:
{
  time.timeZone = "Pacific/Auckland";
  boot = {
    consoleLogLevel = 0;
    initrd.verbose = false;
    plymouth.enable = true;
    kernelParams = [
      "quiet"
      "splash"
      "loglevel=3"
      "vga=current"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
      "snd_hda_intel.power_save=0"
      "snd_hda_intel.power_save_controller=N"
    ];

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      systemd-boot.configurationLimit = 5;
      timeout = 1;
    };

    supportedFilesystems = [ "ntfs" ];
    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };
}
