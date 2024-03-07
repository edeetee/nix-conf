{
	inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
	inputs.flamenco.url = "path:/home/edeetee/dev/flamenco-nix";
	inputs.nixvim = {
		url = "github:nix-community/nixvim";
		inputs.nixpkgs.follows = "nixpkgs";
	};

	outputs = { self, nixpkgs, nixvim, flamenco, ... }@attrs: {
		nixosConfigurations.nixos-desktop = nixpkgs.lib.nixosSystem {
			system = "x86_64-linux";
			specialArgs = { inherit attrs; };
			modules = [ 
				./configuration.nix 
				nixvim.nixosModules.nixvim 
				./ati-server-hardware-configuration.nix 
				flamenco.nixosModules.flamenco 
				./neovim
			];
		};
	};
}
