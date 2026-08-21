# hardware-configuration.nix for rpi3b
#
# Root filesystem is the SD card. The sdImage builder partitions the card
# with a FAT boot partition and an ext4 root partition labelled NIXOS_SD,
# so the label (not a device path) is stable across cards and USB readers.

{
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # No swap partition — zramSwap in default.nix handles it (1GB RAM).
  swapDevices = [ ];
}
