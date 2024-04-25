{
  # To provide an easy place to see and configure the entire cluster, we collect
  # constants here.
  flake.cluster.infra = {
    aws = rec {
      # Will be stored in the AWS_PROFILE environment variable
      profile = "cardano-monitoring";

      # Email address for ACME certificates in Caddy.
      email = "devops+${profile}@iohk.io";

      # The top level domain. Every machine will receive a subdomain under it.
      # In order for this to work, point this domain to the AWS Route53
      # nameserver within the organization that this cluster is deployed in.
      # Once this value is set, you can run `just show-nameservers` to obtain
      # the correct list of nameservers to set your NS entry to.
      domain = "monitoring.aws.iohkdev.io";

      # This value is available after the CloudFormation configuration has been
      # applied with `just cf state` by running `just kms`.
      # This is also stored in the KMS environment variable.
      # It's mostly used for encryption with SOPS.
      kms = "arn:aws:kms:eu-central-1:463886338519:alias/kmsKey";

      # The default region for new instances. This is also stored in the
      # AWS_REGION environment variable, so CloudFormation will make use of it.
      region = "eu-central-1";

      # All regions we currently have in use.
      # The reason for this being an attrset: we translate this into the count
      # in opentofu.
      # So in order to remove a region entirely, set it to false here first,
      # then run tofu, and finally remove the region from this attrset.
      # Note that removing the initial region may have unforseen consequenses
      # and is untested.
      regions = {"eu-central-1" = true;};

      # A list of S3 buckets used across the cluster.
      # The buckets are created by CloudFormation with `just cf state`.
      buckets = {
        # Storing OpenTofu state.
        state = profile;

        # Storing Mimir metrics for the playground cluster.
        playground = "${profile}-playground";

        # Storing Mimir metrics for the mainnet cluster.
        mainnet = "${profile}-mainnet";

        # Storing Mimir metrics for the networkteam cluster.
        networkteam = "${profile}-networkteam";
      };
    };

    # Mostly generic key/values used for tagging resources.
    generic = {
      organization = "iog";
      tribe = "coretech";
      function = "cardano-monitoring";
      repo = "https://github.com/input-output-hk/cardano-monitoring";
      environment = "generic";
    };
  };
}
