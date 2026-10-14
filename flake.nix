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
    # Declarative KDE Plasma settings, a home-manager module. Only
    # homeserver-edt uses it (see nixosConfigurations below); it is a flake
    # input rather than a vendored module because it tracks Plasma's own
    # option churn, which is exactly what we do not want to maintain here.
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
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

    # NB: sink-pi is deliberately NOT an input or an output here. It is a *split
    # flake* at sink-pi/flake.nix, because it depends on the private edeetee/sink
    # repository and Nix resolves every input of a flake for every command that
    # evaluates it - even one that never uses the input. An input here would make
    # this whole flake (and therefore homeserver-edt, rpi3b and the Darwin
    # configurations) need read access to that repository before it could be
    # evaluated at all. Deploy and image builds for that host go through
    # scripts/sink-pi-{switch,image}.sh, which build it with `--dir sink-pi`.
    # See hosts/sink-pi/README.md, "A split flake".
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
      plasma-manager,
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
          modules =
            commonModules
            ++ [
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
            ]
            ++ extraModules
            ++ [
              {
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.${username} = import ./darwin/home.nix (
                  {
                    inherit homeDirectory;
                    username = username;
                  }
                  // homeArgs
                );
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
          # Declarative Plasma settings (hosts/homeserver-edt/kde.nix).
          #
          # home-manager is wired here and NOT in commonModules: that list is
          # also fed to mkDarwin, which already imports the *darwin* HM module
          # through nix-darwin. rpi3b deliberately gets neither.
          home-manager.nixosModules.home-manager
          {
            # One nixpkgs instantiation instead of two.
            home-manager.useGlobalPkgs = true;
            # NixOS-native package handling: HM's own packages (man-db,
            # shared-mime-info, hm-session-vars.sh, ...) are built into
            # /etc/profiles/per-user/edeetee by users.users.edeetee.packages at
            # switch time. The default (false) would instead have HM's
            # activation run `nix-env -i home-manager-path` at boot, mutating
            # ~/.nix-profile — which on this host holds a hand-installed
            # nixops-1.7 from years ago and is not ours to rewrite.
            home-manager.useUserPackages = true;
            home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
          }
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

      # sink-pi (the Raspberry Pi 3B+ MIDI instrument) is deliberately not here: it is
      # a split flake at sink-pi/flake.nix, because its private `sink` input would
      # otherwise have to be resolved by every command that evaluates this flake. See
      # the comment on the inputs above, and hosts/sink-pi/README.md.

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
