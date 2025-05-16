{
  self,
  inputs,
  lib,
  ...
}: {
  # Provides a `.#colmena` output for this flake.
  flake.colmena = {
    # Some basic configuration for colmena.
    meta = {
      # All machines are running on ARM CPUs, so we specify that here to make
      # sure all packages are compiled for the correct architecture.
      nixpkgs = import inputs.nixpkgs {system = "aarch64-linux";};

      # imports can use these arguments as well.
      # `inputs` here refers to our top-level flake inputs
      # `self` is the top-level flake
      specialArgs = {inherit inputs self;};
    };

    # Every machine imports the following modules
    defaults.imports = [
      # Disables graphics, documentation, and other bloat.
      # "${inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
      # Provides SSH logins for GitHub users and teams.
      inputs.auth-keys-hub.nixosModules.auth-keys-hub
      # Handles Secret decryption and use for systemd services
      inputs.sops-nix.nixosModules.default
      # A tiny module specifies AWS resource properties for each machine instance.
      # defined in flake/nixosModules/aws.nix
      self.nixosModules.aws
      # Common NixOS configuration that is required for each machine.
      # defined in flake/nixosModules/common.nix
      self.nixosModules.common
      # Specific configuration for Grafana/Prometheus/Mimir
      # defined in flake/nixosModules/monitoring.nix
      self.nixosModules.monitoring
      # Cleanup for the SSH bootstrap key
      # defined in flake/nixosModules/remove-ssh-bootstrap.nix
      self.nixosModules.remove-ssh-bootstrap-key
    ];

    # Every attribute apart from `meta` and `defaults` defines a machine deployment.
    # These are empty right now because the default imports suffice.

    # Provides a place to store and view metrics for https://github.com/input-output-hk/cardano-playground
    playground = {
      aws.instance.root_block_device.volume_size = 100;
      services.mimir.configuration.limits.compactor_blocks_retention_period = lib.mkForce "10y";
    };

    # Provides a place to store and view metrics for https://github.com/input-output-hk/cardano-mainnet
    mainnet = {
      aws.instance.root_block_device.volume_size = 100;
      services.mimir.configuration.limits.compactor_blocks_retention_period = lib.mkForce "10y";
    };

    # Provides a place to store and view metrics for https://github.com/input-output-hk/ouroboros-network-ops
    networkteam = {
      aws.instance.root_block_device.volume_size = 100;
    };

    # Provides a place to store and view metrics for https://github.com/input-output-hk/devx-ci
    devxci = {
      aws.instance.root_block_device.volume_size = 100;
    };
  };
}
