{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # NixOS-specific
    flamenco.url = "github:edeetee/flamenco-nix";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Secret management — sops-nix
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Darwin-specific
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
    deskflow-tap = {
      url = "https://github.com/deskflow/homebrew-tap";
      flake = false;
    };

    # Shared
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jjui.url = "github:idursun/jjui";
    hunk.url = "github:modem-dev/hunk";
    nixvim-vsc.url = "path:./nvim-vsc";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # sink: the MIDI instrument that runs on the sink-pi host (Raspberry Pi 3B+).
    #
    # `git+ssh` rather than `github:` because the repository is private: the
    # `github:` fetcher goes through api.github.com anonymously unless an
    # `access-tokens` entry is configured, and returns 404 for it. Anything that
    # evaluates this flake (nix flake check, nixos-rebuild on another machine) needs
    # SSH access to github.com:edeetee/sink as a result; the deploy wrappers do not,
    # because they override this input with the local checkout. Note that Nix fetches
    # *every* input of a flake before evaluating any output, so a machine that cannot
    # read this repository cannot evaluate homeserver-edt either - fix the access
    # (deploy key / access-tokens) before running nixup anywhere that needs it.
    #
    # Tracked on `main` for normal life; scripts/sink-pi-switch.sh overrides it with
    # the local checkout (~/dev/sink) at build time, so a change there is what gets
    # built.
    #
    # sink's own nixpkgs and bluez-nixpkgs follow ours: the application is built with
    # *this* flake's pkgs regardless (services.sink.package defaults to
    # pkgs.callPackage inside the module, and pkgs is the host's), so sink's nixpkgs
    # only feeds sink's packages/devShell and its standalone reference image. Following
    # saves fetching a second nixpkgs twice over. The price is that
    # nix/packages/sink.nix's assumptions - Python 3.12, numpy 2, the pinned Pedalboard
    # wheel - have to hold on our nixpkgs.
    sink = {
      url = "git+ssh://git@github.com/edeetee/sink";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.bluez-nixpkgs.follows = "bluez-nixpkgs";
    };

    # BlueZ 5.87 for the Pi's Bluetooth speaker. The nixpkgs this flake locks carries
    # 5.86, whose A2DP regression connects a2dp-source and a2dp-sink at once so
    # neither completes (the transport is dropped moments after the speaker connects);
    # 5.87 has the fix. pi-sink.nix patches this one for the cached-capabilities bug
    # 5.87 introduced, so it is a local compile that no binary cache has - delete this
    # input, the bluezPackage line for sink-pi and patchA2dpCacheBug once our nixpkgs
    # carries a BlueZ with both fixes.
    bluez-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://home-manager.cachix.org"
      "https://nix-darwin.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "home-manager.cachix.org-1:wLVmpPs9J1Na6uhEkqcJcdSmPR61rd76jOnlps6zvM8="
      "nix-darwin.cachix.org-1:LxMyKzQk7Uqkc1Pfq5uhm9GSn07xkERpy+7cpwc006A="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      nixvim,
      hunk,
      flamenco,
      nix-darwin,
      home-manager,
      nix-homebrew,
      homebrew-core,
      homebrew-cask,
      nixvim-vsc,
      nix-index-database,
      sops-nix,
      nixos-hardware,
      sink,
      bluez-nixpkgs,
      ...
    }:
    let
      # Modules shared across all machines (NixOS + Darwin)
      commonModules = [
        (import ./modules/common.nix { inherit hunk; })
        ./modules/nixvim
      ];

      # Helper: build a Darwin configuration from a declarative spec
      mkDarwin =
        {
          username,
          homeDirectory,
          extraModules ? [ ],
          homeArgs ? { },
        }:
        nix-darwin.lib.darwinSystem {
          modules = commonModules ++ [
            nix-homebrew.darwinModules.nix-homebrew
            (import ./darwin/configuration.nix {
              inherit
                self
                homebrew-core
                homebrew-cask
                nixvim-vsc
                ;
              user = username;
            })
            nixvim.nixDarwinModules.nixvim
            home-manager.darwinModules.home-manager
            nix-index-database.darwinModules.nix-index
          ] ++ extraModules ++ [
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.${username} = import ./darwin/home.nix ({
                inherit homeDirectory;
                username = username;
              } // homeArgs);
              home-manager.backupFileExtension = "home-manager-backup";
            }
          ];
        };
    in
    {
      # ── NixOS ──────────────────────────────────────────────────────────

      nixosConfigurations.homeserver-edt = nixpkgs.lib.nixosSystem {
        modules = commonModules ++ [
          ./hosts/homeserver-edt
          nixvim.nixosModules.nixvim
          nix-index-database.nixosModules.default
          sops-nix.nixosModules.sops
        ];
      };

      # Raspberry Pi 3B — always-on DeepSeek harness client over ZeroTier.
      # Built on the homeserver via qemu-user emulation (see hosts/rpi3b/install.md);
      # the Pi itself never compiles. Deliberately NOT importing commonModules or
      # nixvim — 1GB RAM, thin-client role.
      nixosConfigurations.rpi3b = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-3
          ./hosts/rpi3b
        ];
      };

      # Raspberry Pi 3B — the sink MIDI instrument (hosts/sink-pi). The machine is
      # the host directory; everything that is true because *sink runs on a Pi*
      # comes from the sink flake's `nixosModules.piSink`, and the machine-wide
      # policy a shared Pi would own once (kernel params, swap, governor, the deploy
      # user, the boot report) from modules/nixos/sink-machine.nix, which the host
      # imports. Deliberately NOT importing commonModules or nixvim — 1GB RAM, and
      # this box is an instrument.
      #
      # Deploy and image builds go through scripts/sink-pi-{switch,image}.sh, which
      # override `sink` with the local checkout; they never touch this lock file.
      # See hosts/sink-pi/README.md.
      nixosConfigurations.sink-pi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ./hosts/sink-pi
          sink.nixosModules.piSink
          {
            services.sink.pi.bluetooth.bluezPackage =
              bluez-nixpkgs.legacyPackages.aarch64-linux.bluez;
          }
        ];
      };

      # ── Images ─────────────────────────────────────────────────────────
      # nix build .#images.sink-pi -> result/sd-image/*.img. The wrapper is
      # scripts/sink-pi-image.sh, which does the same build in the aarch64 container
      # and copies only the image out.

      images.sink-pi = self.nixosConfigurations.sink-pi.config.system.build.sdImage;

      # ── Darwin ─────────────────────────────────────────────────────────

      darwinConfigurations."Edwards-MacBook-Max" = mkDarwin {
        username = "edeetee";
        homeDirectory = "/Users/edeetee";
      };

      darwinConfigurations."Edwards-MacBook-Air" = mkDarwin {
        username = "edt";
        homeDirectory = "/Users/edt";
      };

      darwinConfigurations."edt-starboard-macbook-pro" = mkDarwin {
        username = "edwardtaylor";
        homeDirectory = "/Users/edwardtaylor";
        extraModules = [ { homebrew.casks = [ "hammerspoon" ]; } ];
        homeArgs = {
          gitEmail = "edward.taylor@starboard.nz";
          hammerspoon = true;
        };
      };

      # ── Formatter ──────────────────────────────────────────────────────
      # Run: nix fmt

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-rfc-style;

      # ── Checks ─────────────────────────────────────────────────────────
      # Run: nix flake check

      checks.aarch64-darwin.jj-worktree =
        (import ./lib/jj-tools {
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        }).checks.jj-worktree-test;
    };
}
