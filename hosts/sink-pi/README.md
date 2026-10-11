# sink-pi — the instrument box

A Raspberry Pi 3B+ with a MIDI keyboard on USB and the onboard 3.5 mm jack for
output. It boots straight into `sink run`; nothing on it needs a terminal, and
nothing on it compiles anything.

This file is how the box is built, deployed and watched from **this** repository. The
application and the "what sink needs from a Pi" layer live in a second repository,
[`~/dev/sink`](https://github.com/edeetee/sink); the reasoning behind both halves is
documented there (`nix/README.md` is the build manual, `plans/raspberry-pi-image.md` the
design record, and `nix/nix-conf/README.md` the extraction that put this host here).

## The two repositories

| | owns |
|---|---|
| `~/dev/sink` | the application (`services.sink`), the Pi seam (`nixosModules.piSink`: the 460800 Bluetooth overlay, BlueALSA, the ALSA plugin path, the service tweaks), and a reference copy of the machine so the image can still be built from there |
| `~/dev/nix-conf` | the machine: this host, the reusable box policy in `modules/nixos/sink-machine.nix`, the flake wiring, and the wrappers that build both together |

The rule when something is ambiguous: **if changing it would be meaningless on a
non-Pi NixOS box running sink, it belongs in `~/dev/sink/nix/pi-sink.nix`; otherwise it
belongs here.**

The seam is the flake input. `flake.nix` takes `sink` as an input and imports
`sink.nixosModules.piSink` into `nixosConfigurations.sink-pi`; the wrappers below
*override* that input with the local checkout, so a change in `~/dev/sink` is what gets
built — committed or not, as long as the file is **tracked by git** (an untracked file
is invisible to `git+file://`, the same property `hosts/sink-pi/local.nix` relies on).
No `nix flake lock` step is needed in the loop.

> **The `sink` input is private.** `flake.nix` points at
> `git+ssh://git@github.com/edeetee/sink` rather than `github:edeetee/sink`, because the
> `github:` fetcher goes through `api.github.com` anonymously and 404s on it. Anything
> that evaluates this flake without the override — `nix flake check`, `nixup` on the
> homeserver — therefore needs SSH access to that repository. The deploy and image
> wrappers do **not**, because they override the input.

## Day to day: a change in sink, one command

```bash
cd ~/dev/nix-conf
./scripts/sink-pi-switch.sh                 # -> sink@sink-pi.local
./scripts/sink-pi-switch.sh 192.168.1.27    # or sink@<address>
```

That runs `~/dev/sink/nix/switch.sh --flake ~/dev/nix-conf --host sink-pi
--sink-repo ~/dev/sink <target>`, which:

1. builds `nixosConfigurations.sink-pi` in a `linux/arm64` Docker container with the
   `sink` input overridden by `~/dev/sink` (`--override-input sink git+file:///src-sink
   --no-write-lock-file`),
2. asks the Pi which paths it is missing and copies only those,
3. activates the system over `sink@` with sudo.

`SINK_REPO` (default `~/dev/sink`) moves the checkout, and `SINK_HOST` the flake
attribute. Under the hood the build is the sink repository's own container recipe: the
machine is where `aarch64-linux` is native and the work lands on this Mac's CPU, not
the Pi's — one measured `--build-on-pi` switch moved ~4,700 paths to deliver 0.63 MB,
which is why it is not the default.

The equivalent without the wrapper, from the sink checkout:

```bash
nix/switch.sh --flake ~/dev/nix-conf --sink-repo ~/dev/sink sink@192.168.1.27
```

### Changing the machine

Edit `hosts/sink-pi/default.nix` (this box) or `modules/nixos/sink-machine.nix` (shared
box policy) and run exactly the same command. The wrapper does not care which
repository changed. `nixos-rebuild` on `homeserver-edt` pulls this tree; nothing here
touches the other hosts.

### Pinning, for machines that are not this laptop

The override is a developer convenience. `flake.lock` is the real record: on a machine
without a sink checkout, `nixos-rebuild --flake .#sink-pi` uses exactly the revision
the lock records. Move it deliberately, after pushing sink:

```bash
nix flake update sink
```

## A fresh SD card

```bash
cd ~/dev/nix-conf
./scripts/sink-pi-image.sh          # -> ~/dev/sink/build/sink-pi.img
~/dev/sink/nix/flash-sd.sh          # READ-ONLY: finds the card, prints what it would do
~/dev/sink/nix/flash-sd.sh --write /dev/disk6   # you run this yourself
```

`scripts/sink-pi-image.sh` runs `~/dev/sink/nix/build-image.sh --flake ~/dev/nix-conf
--image images.sink-pi --sink-repo ~/dev/sink`, so the image is built from *this* flake
and lands in the sink checkout, which is where `flash-sd.sh` looks for it. (The plain
attribute is `nix build .#images.sink-pi` → `result/sd-image/*.img`; note `nix flake
check` warns "unknown flake output 'images'", which is cosmetic — the attribute builds.)

Writing the card is the human's command, not an agent's: `flash-sd.sh` in read-only
mode is safe and prints what the write would do; `--write` is destructive and refuses
anything that looks like a boot disk. `/dev/disk0` on this Mac is the boot disk, and no
rebuild undoes that.

## Watching it

`~/dev/sink/nix/logs.sh` takes any target and works from either repository:

```bash
~/dev/sink/nix/logs.sh sink@192.168.1.27                  # follow the synth's journal
~/dev/sink/nix/logs.sh sink@192.168.1.27 "sink diag"      # or run one command
~/dev/sink/nix/logs.sh -b sink@192.168.1.27               # the boot log
```

The Pi's address is a DHCP lease (`192.168.1.26`, then `.27`, …) and `sink-pi.local`
does not resolve from this Mac even though the box publishes it over avahi; find it
with a `ping` sweep and the `b8:27:eb` MAC prefix, or read it off the router. When the
network itself is broken, the box writes a boot report to the firmware partition —
FAT32, so macOS mounts it by itself:

```
/boot/firmware/sink-booted.txt    the earliest marker: the kernel got as far as sysinit
/boot/firmware/sink-report.txt    system, network, wireless, wpa_supplicant, sink, audio
/boot/firmware/sink-report-previous.txt   the boot before, for comparison
```

## Secrets

`hosts/sink-pi/local.nix` holds the WiFi network and **ships with placeholders**
(`ssid = "CHANGEME"`, an all-zero `pskRaw`). Fill it in *in place* and do not commit the
result — the file is tracked so that an uncommitted edit is still visible to the flake,
which is the point of committing the placeholder version. Derive the key rather than
storing the passphrase:

```bash
python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha1", sys.argv[1].encode(), sys.argv[2].encode(), 4096, 32).hex())' PASSPHRASE SSID
```

`git diff hosts/sink-pi/local.nix` should show your network and nothing you commit
should contain it. (The sink repository's own `nix/local.nix` currently *does* commit
the real values; the drop-in copy here was deliberately blanked.)

Who may log in lives in `hosts/sink-pi/authorized_keys.txt` (a whitelist of public
keys, used for both `sink` and `root`). Edit it here; it has no other source.

## Where each piece lives, and why

The reference host in the sink repository is one machine, so it can set machine-wide
options directly. The requirement here is that the sink system be *composable* — that a
Pi which runs sink alongside other things can include the same behaviour without the
sink host taking the machine over, and without two hosts defining the same option
differently. Each item from that reference host was therefore given a home:

**Into `modules/nixos/sink-machine.nix`** (an option each, defaults reproducing the
reference; the shared host states them once):

| item | why here |
|---|---|
| `boot.kernelParams` | it is a *merged list*, and `console=ttyAMA0` must be removed: ttyAMA0 is the PL011 the Bluetooth chip talks on, so printk would be written into the HCI stream. Removing an entry from a merged list needs `mkForce`, so exactly one module can own the list — hence an option, with the WiFi country (`wifiCountry`) passed in rather than left in a second definition. |
| `zramSwap` + `/swapfile` (`zramSwap`, `swapFileSize`) | 1 GB board policy, not a property of the instrument. Options, so a host with its own swap partition says `swapFileSize = null`. |
| `powerManagement.cpuFreqGovernor` (`cpuGovernor`) | machine-wide; a lazy governor is an audio-dropout source, but a host that pins frequency itself would otherwise collide. |
| `services.getty.autologinUser` (`consoleAutologin`) | the console is the box's, not sink's. Set with `lib.mkDefault` so a host can log in someone else. |
| `security.sudo.wheelNeedsPassword` + `wheel` (`passwordlessSudo`) | the privileged path a container-built deploy activates through. `mkDefault`, and a switch to turn it off on a root-only box. |
| `services.openssh` | machine-wide; `mkDefault` on `enable` and every setting, so a shared host's own SSH policy wins instead of colliding. |
| `networking.firewall.allowedTCPPorts = [ 47811 ]` (`statusPort`) | sink's read-only status socket, so it belongs with sink; a list, so it merges with whatever else the host opens. |
| `nix.settings.trusted-users` | container-built deploys arrive unsigned and the daemon refuses those from an untrusted client. Derives the user from `services.sink.user`. |
| the boot report and the `/boot/firmware` mount (`bootReport`) | the same debugging affordance on any Pi built from nixpkgs' SD-image module, so it can be stated once and turned off. |

**Left in `hosts/sink-pi/default.nix`** (this box's identity and its instrument):

`networking.hostName`, `time.timeZone`, `system.stateVersion`, the SD-image and minimal
profiles, `boot.kernelModules`, the wireless firmware packages, `sdImage.compressImage`,
the authorized keys, `services.avahi`, the WiFi network (`networking.wireless`,
`dhcpcd.wait`, interface naming, power-save-off, the wpa_supplicant retry), and the
whole `services.sink` block — preset, params, samplerate/blocksize/latency and the
speaker address. These say *which* box this is, and another host wanting different
values would not share this file.

### One fix that came out of the move

The reference host's `/boot/firmware` redefinition never worked. nixpkgs'
`sd-image.nix` defines that filesystem with `noauto` (`options` is a *list*, and lists
merge), so a plain redefinition that adds `rw` kept the `noauto`:

```
nix eval ...fileSystems."/boot/firmware".options
# reference:  ["rw" "nofail" "umask=0022" "nofail" "noauto"]   (and /etc/fstab kept it)
```

The partition was never mounted, so every boot report was written to the ext4 root —
exactly the filesystem macOS cannot read, which is the whole reason the report exists.
The module now uses `lib.mkForce` to replace the list, and the early marker is ordered
`after local-fs.target` so the mount is up before it writes. The same fix was applied to
the reference host in the sink repository.

## Verifying a change without deploying

```bash
nix flake check --no-build
nix eval --raw .#nixosConfigurations.sink-pi.config.system.build.toplevel.drvPath
nix eval --raw .#images.sink-pi.drvPath
```

A real `sink` switch, a real image build (needs Docker) and anything that writes the SD
card are deliberate, user-run steps — never an agent's foreground command.
