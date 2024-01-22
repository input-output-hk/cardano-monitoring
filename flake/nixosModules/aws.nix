{
  inputs,
  self,
  ...
}: {
  flake.nixosModules.aws = {
    lib,
    name,
    ...
  }: {
    imports = [
      # All virtualized instances on AWS require this module, it mostly sets up
      # the kernel, initrd, filesystems, and AWS metadata fetching.
      "${inputs.nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
    ];

    options = {
      aws = {
        instance = lib.mkOption {
          type = lib.types.attrs;
          default = {
            # The count is required for opentofu, we can safely destroy an
            # instance by setting the count to 0. Without this, opentofu will
            # complain that the resource just vanished from the configuration.
            count = 1;

            # We use t4g.xlarge because it provides excellent performance for the price.
            # The xlarge size comes with:
            # 4 vCPU Graviton2 at 40% baseline performance
            # 16GiB RAM
            # 96 CPU credits per hour up to a total of 2780
            #
            # At the moment we are barely using any resources, with a stable
            # baseline of about 1-2% CPU and 6-10% of RAM. So in future we may decide
            # to scale the instances down.
            instance_type = "t4g.xlarge";

            # The volume size was chosen initially based on our old monitoring instances.
            # Since we now store metrics in S3 instead, we currently have only
            # about 15GiB of actually required space, mostly for the nix store.
            root_block_device.volume_size = 100;

            # Setting tags on all our resources to adhere to:
            # https://github.com/input-output-hk/sre-adrs/blob/master/decisions/0001-organize-infrastructure-via-tags.md
            tags = {
              inherit (self.cluster.infra.generic) organization tribe function repo;
              environment = name;
              group = name;
              Name = name;
            };
          };
        };

        # Determines the region that the instance will run in.
        region = lib.mkOption {
          type = lib.types.str;
          # We run everything # in the same region right now, so this is
          # specified globally in the cluster configuration.
          default = self.cluster.infra.aws.region;
        };
      };
    };
  };
}
