{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # NixOS-specific
    flamenco.url = "github:edeetee/flamenco-nix";

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
    workmux.url = "github:raine/workmux";
    jjui.url = "github:idursun/jjui";
    nixvim-vsc.url = "path:./nvim-vsc";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixvim,
      flamenco,
      nix-darwin,
      home-manager,
      nix-homebrew,
      homebrew-core,
      homebrew-cask,
      nixvim-vsc,
      workmux,
      ...
    }:
    let
      # NixOS-specific inline config
      nixos-flake-conf =
        { pkgs, ... }:
        {
          environment.shellAliases = {
            nixrs = "sudo nixos-rebuild switch";
          };
        };

      commonModules = [
        (import ./common-configuration.nix { inherit workmux; })
        ./neovim
      ];

      darwinModules =
        user:
        commonModules
        ++ [
          nix-homebrew.darwinModules.nix-homebrew
          (import ./darwin/configuration.nix {
            inherit
              user
              self
              homebrew-core
              homebrew-cask
              nixvim-vsc
              ;
          })
          nixvim.nixDarwinModules.nixvim
          home-manager.darwinModules.home-manager
        ];
    in
    {

      # NixOS
      nixosConfigurations.nixos-desktop = nixpkgs.lib.nixosSystem {

        modules = commonModules ++ [
          ./configuration.nix
          nixvim.nixosModules.nixvim
          ./ati-server-hardware-configuration.nix
          flamenco.nixosModules.flamenco
          nixos-flake-conf
        ];
      };

      # Darwin
      darwinConfigurations."Edwards-MacBook-Max" = nix-darwin.lib.darwinSystem {

        modules = darwinModules "edeetee" ++ [
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.edeetee = import ./darwin/home.nix {
              homeDirectory = "/Users/edeetee";
              username = "edeetee";
              configDir = "${self}/darwin";
            };
            home-manager.backupFileExtension = "home-manager-backup";
          }
        ];
      };

      darwinConfigurations."Edwards-MacBook-Air" = nix-darwin.lib.darwinSystem {

        modules = darwinModules "edt" ++ [
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.edt = import ./darwin/home.nix {
              homeDirectory = "/Users/edt";
              username = "edt";
              configDir = "${self}/darwin";
            };
            home-manager.backupFileExtension = "home-manager-backup";
          }
        ];
      };

      darwinConfigurations."edt-starboard-macbook-pro" = nix-darwin.lib.darwinSystem {

        modules = darwinModules "edwardtaylor" ++ [
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.edt = import ./darwin/home.nix {
              homeDirectory = "/Users/edwardtaylor";
              username = "edwardtaylor";
              configDir = "${self}/darwin";
              karabinerSource = ./darwin/karabiner.json;
              gitEmail = "edward.taylor@starboard.nz";
            };
            home-manager.backupFileExtension = "home-manager-backup";
          }
        ];
      };

      darwinPackages = self.darwinConfigurations."Edwards-MacBook-Max".pkgs;
    };
}
