# rpi3b — install & deploy

A Raspberry Pi 3B running a minimal NixOS (aarch64-linux) as an always-on
agent host, reachable over ZeroTier. **It never compiles anything** — all
builds happen on the homeserver under qemu-user emulation.

## Prerequisites (done once, on the homeserver)

The server must be able to build `aarch64-linux`. Add to
`hosts/homeserver-edt` (or wherever the build host lives):

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];   # qemu-user via binfmt
nix.settings.extra-platforms = [ "aarch64-linux" ];  # nix may build aarch64 here
```

`nixpkgs-unstable` publishes aarch64-linux binary caches, so most of the
closure is a download; only local derivations (system closure, image
assembly) run emulated. First build 10–40 min, incremental afterwards.

## 1. Build the SD image (on the server)

```bash
nix build .#nixosConfigurations.rpi3b.config.system.build.sdImage
# → result/sd-image-rpi3b-aarch64-linux.img.zst
```

## 2. Flash the SD card (from the Mac)

```bash
zstd -d < result/sd-image-rpi3b-aarch64-linux.img.zst | \
  sudo dd of=/dev/rdiskX bs=4m conv=fsync   # ⚠️ check the disk number!
```

## 3. First boot

The stock NixOS ARM image boots with SSH enabled and an **empty root
password** (this config keeps password auth on until you tighten it).
Plug in **ethernet for the first boot** — the WiFi credentials aren't in
the image yet, so the first deploy must come over the wire:

```bash
ssh root@<pi-lan-ip>
# 1. copy your SSH key:  mkdir -p ~/.ssh && <append your pubkey>
# 2. clone this repo so later work has a checkout to look at:
git clone https://github.com/<you>/nix-conf ~/dev/nix-conf   # or scp it
```

## 4. Join ZeroTier

The config already declares `joinNetworks = [ "1c33c1ced0f6e11c" ]`
(smart-access-rds). Authorize the node in my.zerotier.com once it shows up,
then the Pi is reachable from anywhere as `172.28.x.x`.

## 5. WiFi (optional but likely wanted)

Declare it in `hosts/rpi3b/networking.nix` so it **survives rebuilds** —
runtime-only `nmcli` connections may not:

```nix
networking.networkmanager.wifi.backend = "iwd";  # or wpa_supplicant
networking.wireless = {
  enable = true;
  networks."<ssid>".psk = "<password>";   # or use a secrets mechanism
};
```

## 6. Ongoing deploys — never touch the SD card again

```bash
nixos-rebuild switch \
  --flake .#rpi3b \
  --target-host root@<pi-zt-ip> \
  --build-host homeserver-edt.local
```

Builds on the server, copies the closure to the Pi over SSH (WiFi or
ZeroTier — works from anywhere), activates in place. The SD card is only
for initial install; every update after that is a `nixos-rebuild` over the
network. The Pi only needs SSH + nix (default on NixOS) — no compilation.

## Notes

- `zramSwap.enable = true` — 1GB RAM, swap into compressed RAM, no SD wear.
- Don't add `modules/common.nix` or nixvim here: the closure explodes
  (docker, go, postgres, editor) and the Pi crawls.
- The 3B has 10/100 ethernet + 2.4GHz WiFi. Fine for an API client.
