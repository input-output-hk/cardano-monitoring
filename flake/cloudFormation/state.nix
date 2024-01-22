{
  self,
  lib,
  ...
}: {
  # Execute this using: `just cf state`

  flake.cloudFormation.state = let
    inherit (self.cluster.infra.aws) domain buckets;

    tagWith = name: (lib.mapAttrsToList (Key: Value: {
        inherit Key Value;
      }) {
        inherit (self.cluster.infra.generic) organization tribe function repo;
        environment = "generic";
        Name = name;
      });

    mkBucket = name: {
      Type = "AWS::S3::Bucket";
      DeletionPolicy = "RetainExceptOnCreate";
      Properties = {
        Tags = tagWith name;
        BucketName = name;
        BucketEncryption.ServerSideEncryptionConfiguration = [
          {
            BucketKeyEnabled = false;
            ServerSideEncryptionByDefault.SSEAlgorithm = "AES256";
          }
        ];
        VersioningConfiguration.Status = "Enabled";
      };
    };
  in {
    AWSTemplateFormatVersion = "2010-09-09";
    Description = "State handling";

    Resources =
      (lib.mapAttrs (_: mkBucket) buckets)
      // {
        kmsKey = {
          Type = "AWS::KMS::Key";
          DeletionPolicy = "RetainExceptOnCreate";
          Properties = {
            Tags = tagWith "kmsKey";
            KeyPolicy."Fn::Sub" = builtins.toJSON {
              Version = "2012-10-17";
              Statement = [
                {
                  Action = "kms:*";
                  Effect = "Allow";
                  Principal.AWS = "arn:aws:iam::\${AWS::AccountId}:root";
                  Resource = "*";
                  Sid = "Enable admin use and IAM user permissions";
                }
              ];
            };
          };
        };

        kmsKeyAlias = {
          Type = "AWS::KMS::Alias";
          DeletionPolicy = "RetainExceptOnCreate";
          Properties = {
            # KMS aliases do not accept tags
            # This name is used in various places, check before changing it.
            AliasName = "alias/kmsKey";
            TargetKeyId.Ref = "kmsKey";
          };
        };

        DNSZone = {
          Type = "AWS::Route53::HostedZone";
          DeletionPolicy = "RetainExceptOnCreate";
          Properties = {
            HostedZoneTags = tagWith domain;
            Name = domain;
          };
        };

        DynamoDB = {
          Type = "AWS::DynamoDB::Table";
          DeletionPolicy = "RetainExceptOnCreate";
          Properties = {
            Tags = tagWith "opentofu-DynamoDB";
            TableName = "opentofu";

            KeySchema = [
              {
                AttributeName = "LockID";
                KeyType = "HASH";
              }
            ];

            AttributeDefinitions = [
              {
                AttributeName = "LockID";
                AttributeType = "S";
              }
            ];

            BillingMode = "PAY_PER_REQUEST";
          };
        };
      };
  };
}
