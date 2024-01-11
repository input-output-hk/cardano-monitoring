{
  flake.cluster.infra = {
    aws = {
      # Will be stored in the AWS_PROFILE environment variable
      profile = "cardano-monitoring";
      # Region where state is stored
      region = "eu-central-1";
      regions = {"eu-central-1" = true;};
      kms = "arn:aws:kms:eu-central-1:463886338519:alias/kmsKey";
      domain = "monitoring.aws.iohkdev.io";
      bucketName = "cardano-monitoring";
      email = "devops+cardano-monitoring@iohk.io";
    };

    generic = {
      organization = "iog";
      tribe = "coretech";
      function = "cardano-monitoring";
      repo = "https://github.com/input-output-hk/cardano-monitoring";
    };
  };
}
