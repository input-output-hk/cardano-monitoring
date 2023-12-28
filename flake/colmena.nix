{
  self,
  inputs,
  ...
}: {
  flake.colmena = {
    playground = {};
    mainnet = {};

    meta = {
      nixpkgs = import inputs.nixpkgs {system = "aarch64-linux";};
      specialArgs = {inherit inputs self;};
    };

    defaults.imports = [
      inputs.auth-keys-hub.nixosModules.auth-keys-hub
      inputs.sops-nix.nixosModules.default
      self.nixosModules.aws
      self.nixosModules.common
      self.nixosModules.monitoring
    ];
  };
}
