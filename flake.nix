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

    #arr
    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixarr.url = "github:nix-media-server/nixarr";

    # Shared
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # workmux.url = "github:raine/workmux";
    jjui.url = "github:idursun/jjui";
    nixvim-vsc.url = "path:./nvim-vsc";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
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
      # workmux,
      nix-index-database,
      nixarr,
      ...
    }:
    let
      commonModules = [
        (import ./common-configuration.nix {  })
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
          nix-index-database.darwinModules.nix-index
        ];
    in
    {

      # NixOS
      nixosConfigurations.homeserver-edt = nixpkgs.lib.nixosSystem {
        modules = commonModules ++ [
          ./configuration.nix
          ./nixos/steam.nix
          ./nixos/arr.nix
          ./nixos/samba.nix
          nixvim.nixosModules.nixvim
          ./ati-server-hardware-configuration.nix
          # flamenco.nixosModules.flamenco
          nix-index-database.nixosModules.default
          nixarr.nixosModules.default
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
