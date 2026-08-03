{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # NixOS-specific
    flamenco.url = "github:edeetee/flamenco-nix";

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
  };

  nixConfig = {
    extra-substituters = [
      "https://sops-nix.cachix.org"
      "https://nix-community.cachix.org"
      "https://home-manager.cachix.org"
      "https://nix-darwin.cachix.org"
    ];
    extra-trusted-public-keys = [
      "sops-nix.cachix.org-1:YxCuBNRFXP5FfIabNOdYbV7wB4EfH4IVlaokHmGJOmc="
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
                configDir = "${self}/darwin";
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
