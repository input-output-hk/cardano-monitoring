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

    options.aws = {
      instance = lib.mkOption {
        type = with lib.types; attrsOf anything;
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
          root_block_device = {
            volume_size = 100;
            volume_type = "gp3";
            iops = 3000;
            delete_on_termination = true;
          };

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

    config.aws = {
      instance = {
        # The count is required for opentofu, we can safely destroy an
        # instance by setting the count to 0. Without this, opentofu will
        # complain that the resource just vanished from the configuration.
        count = lib.mkDefault 1;

        # We use t4g.xlarge because it provides excellent performance for the price.
        # The xlarge size comes with:
        # 4 vCPU Graviton2 at 40% baseline performance
        # 16GiB RAM
        # 96 CPU credits per hour up to a total of 2780
        #
        # At the moment we are barely using any resources, with a stable
        # baseline of about 1-2% CPU and 6-10% of RAM. So in future we may decide
        # to scale the instances down.
        instance_type = lib.mkDefault "t4g.xlarge";

        # The volume size was chosen initially based on our old monitoring instances.
        # Since we now store metrics in S3 instead, we currently have only
        # about 15GiB of actually required space, mostly for the nix store.
        root_block_device = {
          volume_size = lib.mkDefault 30;
          volume_type = lib.mkDefault "gp3";
          iops = lib.mkDefault 3000;
          delete_on_termination = lib.mkDefault true;
        };

        # Setting tags on all our resources to adhere to:
        # https://github.com/input-output-hk/sre-adrs/blob/master/decisions/0001-organize-infrastructure-via-tags.md
        tags = {
          organization = lib.mkDefault self.cluster.infra.generic.organization;
          tribe = lib.mkDefault self.cluster.infra.generic.tribe;
          function = lib.mkDefault self.cluster.infra.generic.function;
          repo = lib.mkDefault self.cluster.infra.generic.repo;
          environment = lib.mkDefault name;
          group = lib.mkDefault name;
          Name = lib.mkDefault name;
        };
      };

      region = lib.mkDefault self.cluster.infra.aws.region;
    };
  };
}
