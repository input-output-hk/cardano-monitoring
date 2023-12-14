{inputs, ...}: {
  flake.nixosModules.aws = {lib, ...}: {
    imports = ["${inputs.nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"];
    options = {
      aws = {
        instance = lib.mkOption {
          type = lib.types.attrs;
          default = {
            count = 1;
            instance_type = "t4g.xlarge";
            root_block_device.volume_size = 100;
          };
        };

        region = lib.mkOption {
          type = lib.types.str;
          default = "eu-central-1";
        };
      };
    };
  };
}
