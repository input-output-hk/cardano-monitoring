{
  description = "Cardano Monitoring cluster";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    # flake-parts is used to structure this flake. It's particularly convenient
    # for defining outputs for different systems. But also lets us
    # combine different modules.
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.url = "github:NixOS/nixpkgs/nixos-25.05?dir=lib";
    };

    # Used for copying closures to the target machines.
    # We specify our cluster in flake/colmena.nix
    colmena.url = "github:zhaofengli/colmena";

    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    inputs-check = {
      url = "github:input-output-hk/inputs-check";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    auth-keys-hub = {
      url = "github:input-output-hk/auth-keys-hub";
      inputs.flake-parts.follows = "flake-parts";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    opentofu-registry = {
      url = "github:opentofu/registry-stable";
      flake = false;
    };
  };

  outputs = {
    flake-parts,
    treefmt-nix,
    inputs-check,
    ...
  } @ inputs: let
    inherit ((import ./flake/lib.nix {inherit inputs;}).flake.lib) recursiveImports;
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux"];

      imports =
        recursiveImports [./flake ./perSystem]
        ++ [
          treefmt-nix.flakeModule
          inputs-check.flakeModule
        ];
    };

  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
  };
}
