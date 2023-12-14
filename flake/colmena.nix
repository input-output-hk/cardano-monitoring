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
      self.nixosModules.common
      self.nixosModules.opentofu
      self.nixosModules.aws
      inputs.auth-keys-hub.nixosModules.auth-keys-hub
      inputs.sops-nix.nixosModules.default
      self.nixosModules.monitoring
    ];
  };
}
