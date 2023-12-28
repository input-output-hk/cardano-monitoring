{
  flake.cluster.infra.aws = {
    profile = "cardano-monitoring";
    region = "eu-central-1";
    regions = {"eu-central-1" = true;};
    kms = "arn:aws:kms:eu-central-1:463886338519:alias/kmsKey";
    domain = "monitoring.aws.iohkdev.io";
    bucketName = "cardano-monitoring";
  };
}
