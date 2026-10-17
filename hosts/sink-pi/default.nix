# sink-pi: the instrument box.
#
# A Raspberry Pi 3B+ with a MIDI keyboard on USB and the onboard 3.5 mm jack for
# output. Boots straight into `sink run`; nothing on it needs a terminal, and
# nothing on it can build anything.
#
# This is the machine, and only the machine: hostname, users, wireless, storage and
# the instrument's own settings. Everything that is true because *sink runs on a Pi*
# comes from the sink repository's `nixosModules.piSink` (sink-pi/flake.nix, a sibling
# of hosts/, adds it next to this module), and the machine-wide policy that a shared Pi
# would have to state once - boot parameters, swap, the governor, the deploy user, the
# boot report - comes from modules/nixos/sink-machine.nix, imported below.
# hosts/sink-pi/README.md records which item went where and why, and why this host is
# its own flake.
#
# The sink repository keeps a reference copy of this host (`nix/hosts/sink-pi.nix`)
# so the image can still be built straight from there. It is a snapshot, not a
# source of truth; it is now also a *different* file, because the factoring above has
# no counterpart there.
{ config, lib, pkgs, modulesPath, ... }:

let
  local = import ./local.nix;
  authorizedKeys = builtins.filter (k: k != "") (
    lib.splitString "\n" (builtins.readFile ./authorized_keys.txt)
  );
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
    ../../modules/nixos/sink-machine.nix
    # The AirPlay receiver, in its headless shape (services.airplay.desktop =
    # false below). Same file homeserver-edt imports from desktop.nix, and it
    # reaches nothing in a session when desktop is off.
    ../../modules/nixos/airplay.nix
  ];

  # --- boot ------------------------------------------------------------------
  #
  # The stock nixpkgs aarch64 kernel, deliberately. Its shipped config already
  # enables everything this board needs, which I checked by reading the config
  # rather than assuming: CONFIG_SND_BCM2835=m and CONFIG_BCM2835_VCHIQ=m (the
  # firmware-backed driver that drives the 3.5 mm jack), CONFIG_MMC_BCM2835=y (SD)
  # and CONFIG_BRCMFMAC=m (wireless).
  #
  # The alternative is nixpkgs' `linux_rpi3`, the Raspberry Pi Foundation's
  # downstream kernel, and it buys nothing here while costing a full kernel
  # compile: Hydra does not build it for aarch64, so it cannot be substituted from
  # cache.nixos.org, whereas this one can. A mainline kernel is also what the
  # official generic aarch64 image boots a Pi 3B+ with.
  #
  # Both are modules in mainline, so ask for them explicitly rather than relying on
  # the device-tree modalias being matched. `brcmfmac` matters more than it looks:
  # on a Pi 3B+ the wireless interface appears a few seconds into boot, and if the
  # wireless service starts first it gives up and never retries -- the documented
  # symptom is "WiFi works after `systemctl restart wpa_supplicant` and not before"
  # (nixpkgs issue 82462). Loading the driver early removes the race.
  boot.kernelModules = [
    "snd_bcm2835"
    "brcmfmac"
    # The 3B+'s Ethernet is a USB chip (SMSC LAN7515), so its driver is a module.
    # udev would autoload it; asking for it explicitly means the interface exists
    # before dhcpcd looks for addresses.
    "smsc95xx"
  ];

  # kernelParams (including the removal of console=ttyAMA0, which would write
  # printk into the Bluetooth HCI stream) lives in modules/nixos/sink-machine.nix:
  # it is a merged list option, so exactly one module may own it. The WiFi country
  # it needs is passed through below.

  # There is no ZFS here, and 26.05 warns about the old default.
  boot.zfs.forceImportRoot = false;

  # Note: no `options snd_bcm2835 enable_hdmi=0` here on purpose. That parameter
  # belongs to the downstream driver; the mainline one does not have it, and an
  # unknown module parameter stops the module loading entirely. The HDMI output is
  # avoided by asking for the jack by name instead (`audio.device = "Headphones"`),
  # which works whatever the driver calls its parameters. Check with
  # `modinfo snd_bcm2835` on the device before adding anything here.

  # The onboard wireless chip needs its firmware blob, which is not in the kernel.
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [
    pkgs.raspberrypiWirelessFirmware
    pkgs.wireless-regdb # channel/power table for the configured country
  ];

  # --- firmware config.txt ---------------------------------------------------
  #
  # The SD image module writes config.txt itself (kernel=u-boot-rpi3.bin for [pi3],
  # enable_uart=1 for U-Boot) into a firmware partition it has already mounted by
  # the time populateFirmwareCommands runs, so appending to that file from here is
  # denied. Adding lines means replacing the whole command, boot files included,
  # which is not worth doing before the device has told us it needs them.
  #
  # Specifically, `dtparam=audio=on` is the line that might be wanted for the
  # 3.5 mm jack. The Raspberry Pi firmware enables audio by default and nixpkgs'
  # config.txt does not disable it, so the expectation is that the jack is already
  # live; `aplay -l` on the device answers it in one line. It has one: `card 0:
  # Headphones [bcm2835 Headphones]`, with no such line anywhere.

  # Writing an uncompressed image is faster and the card is the slow part anyway.
  sdImage.compressImage = false;

  # --- identity --------------------------------------------------------------
  networking.hostName = "sink-pi";
  time.timeZone = "Pacific/Auckland";

  # The machine policy in modules/nixos/sink-machine.nix, with this box's country
  # for the kernel's regulatory domain.
  sinkMachine = {
    enable = true;
    wifiCountry = local.wifi.country;
  };

  # --- users and remote access ----------------------------------------------
  #
  # ssh, sudo and the console autologin are machine policy and live in
  # modules/nixos/sink-machine.nix. Who may log in is this box's business, so the
  # keys stay here: the sink user needs them for the console/deploy, and root needs
  # them because a container-built switch activates the system over root@ or sink@
  # with sudo.
  users.users.sink.openssh.authorizedKeys.keys = authorizedKeys;
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # So the box answers to sink-pi.local from this Mac, instead of needing an
  # address looked up on the router.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.addresses = true;
    publish.workstation = true;
  };

  # --- wifi ------------------------------------------------------------------
  #
  # wpa_supplicant rather than NetworkManager: one network, never changes, no
  # roaming, no interactive use. Note the Pi 3B+ radio is 2.4 GHz only, so the
  # SSID has to exist on 2.4 GHz. `pskRaw` is the key derived from the passphrase
  # by PBKDF2, which keeps the passphrase itself out of the world-readable Nix
  # store (anyone with `pskRaw` can join the network, but it does not reveal a
  # password that might be reused elsewhere). Regenerate with the command in
  # nix/README.md, and see "Secrets" there for why this file is committed with
  # placeholders and edited in place.
  #
  # A lease is not a reason to hold up the boot. Nothing on this box is ordered
  # after network-online.target (checked: the target has no dependents), and the
  # instrument does not touch the network at all - its status socket binds 0.0.0.0
  # and works without an address. The default is to wait for an address, which on
  # this box arrives at about 55 seconds because the WiFi association that produces
  # it is slow, so the wait costs a measured 26.8 seconds of boot time and buys
  # nothing. The address still arrives; it just no longer blocks multi-user.target.
  networking.dhcpcd.wait = "background";

  networking.wireless = {
    enable = true;
    networks."${local.wifi.ssid}".pskRaw = local.wifi.pskRaw;
    # Explicit, so a second interface cannot confuse it. Safe because the naming
    # below forces the classic names.
    interfaces = [ "wlan0" ];
  };

  # Classic interface names (`wlan0`, `eth0`) rather than systemd's predictable
  # scheme. A working Pi 3B+ configuration from January 2026 sets this, and it
  # removes a guess: with predictable names the SDIO wireless interface is
  # *probably* still `wlan0`, and this makes it certain.
  networking.usePredictableInterfaceNames = false;

  # Belt and braces for the race above: if wpa_supplicant still starts before wlan0
  # exists, it retries instead of staying failed for the whole uptime.
  systemd.services.wpa_supplicant.serviceConfig = {
    Restart = "on-failure";
    RestartSec = 3;
  };

  # WiFi power saving is a well-known cause of latency spikes and dropouts on these
  # boards: with a weak signal it makes the link look flaky rather than merely weak.
  # There is no declarative option for it, so ask the driver, retrying until the
  # interface exists (it never will if the box is wired-only, which is fine).
  systemd.services.wifi-powersave-off = {
    description = "Disable WiFi power saving";
    wantedBy = [ "multi-user.target" ];
    after = [ "wpa_supplicant.service" ];
    path = [ pkgs.iw ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for _ in 1 2 3 4 5; do
        iw dev wlan0 set power_save off && exit 0
        sleep 2
      done
      exit 0
    '';
  };

  # --- the instrument --------------------------------------------------------
  #
  # The machine-wide half of running it (the status port, the deploy user, the
  # governor, memory) is sink-machine.nix. This is what *this* box plays.
  services.sink = {
    enable = true;
    user = "sink";

    # Where the speaker lives, for the BlueALSA `bt` PCM this module sets up. Null
    # would mean no Bluetooth at all; find the address with `bluetoothctl devices`.
    # The 3.5 mm jack stays the default output whatever this says - the PCM only
    # exists so the speaker *can* be chosen.
    pi.bluetooth.speakerMac = "00:4B:12:F6:26:1E";

    # The Pi 3B+ has four slow cores, and the fat-lead preset is a five-voice
    # unison supersaw: six held notes would be thirty oscillators. So this box
    # opens on a light patch, plays through 44.1 kHz (also the happier rate for
    # the PWM clock) and a large block to keep the per-block overhead down.
    preset = "chip-tune";
    params = {
      volume = 0.25;
      scale = "pentatonic_minor";
      root = "A";
    };
    audio = {
      # Empty means "whatever PortAudio considers the default output", which on this box
      # is the 3.5 mm jack. This is the configuration that played well, so it is the
      # baseline while a live-only fault is chased: naming the card directly
      # (`Headphones`) opened hw:0,0, and that was the newest change in the build that
      # misbehaves - one variable at a time. Revisit it when the fault is understood;
      # opening the card does make the kernel's XRUN reports honest, which is worth
      # having later.
      device = "";
      samplerate = 44100;
      blocksize = 1024;
      # Write to the card with libasound directly, bypassing PortAudio entirely. Its ALSA
      # backend times itself from a playback position this driver only refreshes every
      # 10 ms, and that is the popping: 64 stream restarts in 40 s, and a direct blocking
      # client ran the same card for 15 s at two period sizes with 0 errors. `hw:0,0` is
      # the card, which also skips the `default` plugin PCM. Empty keeps PortAudio; see
      # plans/remove-popping.md, round 2b.
      alsa_device = "hw:0,0";
      # How much audio to ask the card to queue, in microseconds. On this host that
      # number is most of the output latency: the blocking writer is woken only at
      # period boundaries and fills the queue, so the driver's grant sits between the key
      # and the speaker. Measured on this card on 2026-10-03 (plans/latency.md):
      #
      #   sink-direct-probe, 15 s each: 50000 -> 552/2205 frames, 0 errors;
      #   40000 -> 444/1764, 0; 35000 -> 444/1544, 0; 30000 -> 444/1323, 0;
      #   25000 -> 444/1103, 0; 20000 -> 444/882, 27 underruns; 15000 -> 444/662, 551.
      #
      #   Through the engine (six-note fat-lead chord, 1024-frame blocks, five minutes,
      #   pinned to cores 1-3 at nice -19, the way this unit runs): 50000 -> 1 underrun,
      #   40000 -> 1, 25000 -> 120 in 30 s. Mean queued audio 35.0 ms at 50000 against
      #   28.2 ms at 40000.
      #
      # So 40000 is the lowest that behaves like the old 50000, and it is about 7 ms less
      # delay. It cannot go lower while a block occasionally overruns the 23.2 ms budget
      # by 30-100 ms: a stall that long starves any smaller buffer, which is why the
      # supply is the next thing to look at - /sys/class/hwmon/hwmon1/in0_lcrit_alarm
      # reads 1 on this box, and the kernel has logged tens of thousands of voltage
      # events. plans/latency.md has the acceptance test to re-run after that.
      alsa_latency_us = 40000;
    };
    midi.device = "MPK mini";
  };

  # --- airplay ----------------------------------------------------------------
  #
  # A headless receiver: no session here, so the system unit runs shairport-sync
  # and it writes ALSA straight to the card the instrument is on. That is not a
  # fight for the device - the bcm2835 driver exposes eight playback substreams,
  # and a second client is accepted, drained in real time and does not disturb
  # the synth's stream (measured; hosts/sink-pi/AIRPLAY.md has the numbers). What
  # it does *not* do is touch the synth's path: shairport-sync opens the device
  # only while a stream is playing, so an idle receiver holds no audio device at
  # all and the two only share the card during playback.
  #
  # AirPlay 2 (the default, via `airplay2`) brings nqptp and with it the
  # ephemeral-UDP firewall range the module opens; see the module for why. This
  # box can afford the ffmpeg-sized part of that closure, so it keeps it.
  services.airplay = {
    enable = true;
    desktop = false;

    # The same card the instrument opens. Named directly rather than through the
    # `default` plugin PCM, for the reason the synth's alsa_device is hw:0,0 too:
    # the plugin layer does its own format/period conversion, and that was the
    # popping (plans/remove-popping.md).
    outputDevice = "hw:0,0";
  };

  # --- small and headless ----------------------------------------------------
  #
  # The boot report, the firmware partition and the trusted deploy user are in
  # machines/nixos/sink-machine.nix (they are the same on any Pi box); what is left
  # here is this box's own housekeeping.

  # No documentation build: it is a large part of a NixOS closure and this box has
  # no manual pages to read.
  documentation.enable = false;

  services.journald.extraConfig = ''
    SystemMaxUse=128M
    Storage=persistent
  '';

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  boot.tmp.cleanOnBoot = true;

  environment.systemPackages = with pkgs; [
    # Deliberately not alsa-utils. `speaker-test` cannot be trusted anyway (it drains the
    # PCM, which on Bluetooth blocks for bluez's transport timeout and leaves the transport
    # claimed) and `aplay -L` lists nothing for the BlueALSA PCM even when it opens and
    # plays - both cost hours here. `sink-tone` (from nix/pi-sink.nix) and `sink devices`
    # replace them and use the same PortAudio stack as the synth. alsa-utils also pulls
    # alsa-plugins, which pulls ffmpeg, which builds against sdl3, which builds against
    # pipewire: a media stack on a headless board. Reinstating it for amixer/arecord is
    # possible, but expect that cost.
    iw # iw dev / iw dev wlan0 link: is the radio associated at all?
    usbutils # lsusb: is the keyboard actually there?
    kmod # lsmod / modinfo snd_bcm2835
    procps # top/ps
    # The same binary the service runs, so `sink render`, `sink analyse` and an
    # interactive `sink run` are available by name over ssh and at the console.
    config.services.sink.package
    bluez # bluetoothctl: pairing, scanning, connecting
    bluez-alsa # bluealsa-aplay, hcitop: hearing and seeing what the link does
  ];

  system.stateVersion = "26.05";
}
