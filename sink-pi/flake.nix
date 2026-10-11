# sink-pi's own flake — a split flake, deliberately.
#
# This host depends on the private `edeetee/sink` repository, and Nix resolves *every*
# input of a flake for every command that evaluates that flake, even an input the
# command never uses. If `sink` were an input of the repository-root flake, then
# `nix flake check` and `nixos-rebuild` for homeserver-edt, rpi3b and the Darwin
# configurations would all need to read that repository before they could be evaluated
# at all. The cost of the split is that this host is no longer an attribute of the root
# flake; the wrappers build it here instead.
#
# The flake root is a *subdirectory* of the repository, so `--dir` is what tells the
# container how to build it (`git+file:///src?dir=sink-pi#...`) while the whole
# repository is still mounted. That is why the modules below reach `../hosts/...` and
# `../modules/...`: with `?dir=` the entire repository is the source tree and only the
# flake root is this directory, so nothing has to move for the split.
#
# Build, deploy and image, from the repository root:
#
#   ./scripts/sink-pi-switch.sh [sink@<address>]
#   ./scripts/sink-pi-image.sh
#
# which run the sink repository's container recipe against this flake with `--dir
# sink-pi`, overriding the `sink` input with the local checkout so a change there is
# what gets built. See ../hosts/sink-pi/README.md, "A split flake".
{
  description = "sink-pi: the sink MIDI instrument box (Raspberry Pi 3B+)";

  inputs = {
    # The exact revision the board has been proved on: 26.05.20260924.c508844, kernel
    # 6.18.53. That is what this Pi's previous generations are and what the sink
    # repository pins, so every latency, underrun and popping measurement in that
    # repository was taken on it - and so the package set does not move at the same time
    # as the machine configuration (one variable at a time). A fixed rev rather than the
    # floating nixos-26.05 on purpose: to move it, change the rev here and re-lock.
    nixpkgs.url = "github:NixOS/nixpkgs/c508844df6c28fa6dabc1b6af70f3ccbd65c5201";

    # The instrument itself. Private, hence `git+ssh`: the `github:` fetcher goes
    # through api.github.com anonymously unless an `access-tokens` entry is configured,
    # and returns 404 for it. Anything that evaluates this flake needs SSH access to
    # github.com:edeetee/sink; the deploy wrappers do not, because they override the
    # input with the local checkout.
    sink = {
      url = "git+ssh://git@github.com/edeetee/sink";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.bluez-nixpkgs.follows = "bluez-nixpkgs";
    };

    # The same BlueZ the board was proved with: the sink repository's pinned
    # nixpkgs-unstable rev, whose 5.87 carries the A2DP source-after-sink fix. A fixed
    # rev, so the patched BlueZ is byte-for-byte what was measured rather than whatever
    # a branch moved to today. pi-sink.nix still applies its one-hunk
    # cached-capabilities patch on top (5.87 needs it), which is a local compile no
    # binary cache has - drop this input, the bluezPackage line below and
    # patchA2dpCacheBug once the pinned nixpkgs carries a BlueZ with both fixes.
    bluez-nixpkgs.url = "github:NixOS/nixpkgs/d54020a6ac3211e9f4201631bdf67678818c0cdf";
  };

  outputs =
    {
      self,
      nixpkgs,
      sink,
      bluez-nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;
    in
    {
      nixosConfigurations.sink-pi = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ../hosts/sink-pi
          ../modules/nixos/sink-machine.nix
          sink.nixosModules.piSink
          {
            services.sink.pi.bluetooth.bluezPackage =
              bluez-nixpkgs.legacyPackages.aarch64-linux.bluez;
          }
        ];
      };

      # nix build .#images.sink-pi -> result/sd-image/*.img
      images.sink-pi = self.nixosConfigurations.sink-pi.config.system.build.sdImage;
    };
}
