{
  self,
  inputs,
  lib,
  config,
  ...
}:
with builtins;
with lib; let
  inherit (self.cluster.infra) aws;

  deploySystem = "x86_64-linux";
  monitorSystem = "arm64-linux";

  awsProviderFor = region: "aws.${underscore region}";
  underscore = replaceStrings ["-"] ["_"];

  nixosConfigurations = mapAttrs (_: node: node.config) config.flake.nixosConfigurations;
  nodes =
    filterAttrs (
      name: node:
        (traceVerbose "Evaluating machine: ${name}" node.aws != null) && node.aws.instance.count > 0
    )
    nixosConfigurations;
  mapNodes = f: mapAttrs f nodes;

  regions =
    mapAttrsToList (region: enabled: {
      region = underscore region;
      count =
        if enabled
        then 1
        else 0;
    })
    aws.regions;

  mapRegions = f: foldl' recursiveUpdate {} (forEach regions f);

  buckets = attrValues (filterAttrs (name: _: name != "state") aws.buckets);

  mkSecurityGroupRule = recursiveUpdate {
    protocol = "tcp";
    cidr_blocks = ["0.0.0.0/0"];
    ipv6_cidr_blocks = ["::/0"];
    prefix_list_ids = [];
    security_groups = [];
    self = true;
  };

  mapBuckets = fn: listToAttrs (map fn buckets);

  sensitiveString = {
    type = "string";
    sensitive = true;
    nullable = false;
  };

  defaultTags = {
    inherit
      (self.cluster.infra.generic)
      environment
      function
      organization
      owner
      project
      repo
      tribe
      ;

    # costCenter is saved as a secret
    costCenter = "\${var.${self.cluster.infra.generic.costCenter}}";
  };
  allConfig = {
    terraform = {
      required_providers = {
        aws.source = "opentofu/aws";
        null.source = "opentofu/null";
        local.source = "opentofu/local";
        tls.source = "opentofu/tls";
      };

      backend.s3 = {
        inherit (aws) region;
        bucket = aws.buckets.state;
        key = "opentofu";
        dynamodb_table = "opentofu";
      };
    };

    variable = {
      # costCenter tag should remain secret in public repos
      "${self.cluster.infra.generic.costCenter}" = sensitiveString;
    };

    provider.aws = forEach (attrNames aws.regions) (region: {
      inherit region;
      alias = underscore region;

      # Default tagging is inconsistent across aws resources, but including
      # it may help tag some resources that might have otherwise been
      # missed.
      default_tags.tags = defaultTags;
    });

    resource = {
      aws_instance = mapNodes (_: node: let
        inherit (node.aws) region;
      in
        {
          inherit (node.aws.instance) count instance_type;

          provider = awsProviderFor node.aws.region;
          ami = "\${data.aws_ami.nixos_${underscore monitorSystem}_${underscore region}.id}";
          lifecycle = [{ignore_changes = ["ami" "user_data"];}];
          iam_instance_profile = "\${aws_iam_instance_profile.ec2_profile.name}";
          monitoring = true;
          key_name = "\${aws_key_pair.bootstrap_${underscore node.aws.region}[0].key_name}";
          vpc_security_group_ids = ["\${aws_security_group.common_${underscore node.aws.region}[0].id}"];

          # Provider level `default_tags` are automatically inherited at
          # the instance level.  Instance specific tags defined in
          # flake/colmena.nix are merged.
          tags = node.aws.instance.tags or {};

          root_block_device =
            node.aws.instance.root_block_device
            // {
              # Default tags are not inherited to the volume level automatically.
              tags = defaultTags // node.aws.instance.tags or {};
            };

          metadata_options = {
            http_endpoint = "enabled";
            http_put_response_hop_limit = 2;
            http_tokens = "required";
          };
        }
        // optionalAttrs (node.aws.instance ? availability_zone) {
          inherit (node.aws.instance) availability_zone;
        });

      aws_iam_instance_profile.ec2_profile = {
        name = "ec2Profile";
        role = "\${aws_iam_role.ec2_role.name}";
        tags = defaultTags;
      };

      aws_iam_role.ec2_role = {
        name = "ec2Role";
        assume_role_policy = toJSON {
          Version = "2012-10-17";
          Statement = [
            {
              Action = "sts:AssumeRole";
              Effect = "Allow";
              Principal.Service = "ec2.amazonaws.com";
            }
          ];
        };
        tags = defaultTags;
      };

      aws_s3_bucket_policy = mapBuckets (bucket: {
        name = "allow_${bucket}";
        value = {
          bucket = "\${data.aws_s3_bucket.${bucket}.id}";
          policy = "\${data.aws_iam_policy_document.allow_${bucket}.json}";
        };
      });

      aws_iam_role_policy_attachment = let
        mkRoleAttachments = roleResourceName: policyList:
          listToAttrs (map (policy:
            if isString policy
            then {
              name = "${roleResourceName}_policy_attachment_${policy}";
              value = {
                role = "\${aws_iam_role.${roleResourceName}.name}";
                policy_arn = "\${aws_iam_policy.${policy}.arn}";
              };
            }
            else {
              name = "${roleResourceName}_policy_attachment_${policy.name}";
              value = {
                role = "\${aws_iam_role.${roleResourceName}.name}";
                policy_arn = policy.arn;
              };
            })
          policyList);
      in
        foldl' recursiveUpdate {} [
          (mkRoleAttachments "ec2_role" [
            "kms_user"
            {
              name = "ssm";
              arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore";
            }
          ])
        ];

      aws_iam_policy.kms_user = {
        name = "kmsUser";
        policy = toJSON {
          Version = "2012-10-17";
          Statement = [
            {
              Effect = "Allow";
              Action = ["kms:Decrypt" "kms:DescribeKey"];

              # KMS `kmsKey` is bootstrapped by cloudFormation rain.
              # Scope this policy to a specific resource to allow for multiple keys and key policies.
              Resource = "arn:aws:kms:*:\${data.aws_caller_identity.current.account_id}:key/*";
              Condition."ForAnyValue:StringLike"."kms:ResourceAliases" = "alias/kmsKey";
            }
          ];
        };
        tags = defaultTags;
      };

      aws_route53_record = mapNodes (name: node: {
        zone_id = "\${data.aws_route53_zone.selected.zone_id}";
        name = "${node.monitoring.subdomain}.\${data.aws_route53_zone.selected.name}";
        type = "A";
        ttl = "300";
        records = ["\${aws_eip.${name}[0].public_ip}"];
      });

      tls_private_key.bootstrap.algorithm = "ED25519";

      aws_key_pair = mapRegions ({
        count,
        region,
      }: {
        "bootstrap_${region}" = {
          inherit count;
          provider = awsProviderFor region;
          key_name = "bootstrap";
          public_key = "\${tls_private_key.bootstrap.public_key_openssh}";
          tags = defaultTags;
        };
      });

      aws_eip = mapNodes (name: node: {
        inherit (node.aws.instance) count;
        provider = awsProviderFor node.aws.region;
        instance = "\${aws_instance.${name}[0].id}";

        # Provider level `default_tags` are automatically inherited.
        tags = node.aws.instance.tags or {};
      });

      aws_eip_association = mapNodes (name: node: {
        inherit (node.aws.instance) count;
        provider = awsProviderFor node.aws.region;
        instance_id = "\${aws_instance.${name}[0].id}";
        allocation_id = "\${aws_eip.${name}[0].id}";
      });

      # To remove or rename a security group, keep it here while removing
      # the reference from the instance. Then apply, and if that succeeds,
      # remove the group here and apply again.
      aws_security_group = mapRegions ({
        region,
        count,
      }: {
        "common_${region}" = {
          inherit count;
          provider = awsProviderFor region;
          name = "common";
          description = "Allow common ports";
          lifecycle = [{create_before_destroy = true;}];

          ingress = map mkSecurityGroupRule [
            {
              description = "Allow HTTP";
              from_port = 80;
              to_port = 80;
            }
            {
              description = "Allow HTTPS";
              from_port = 443;
              to_port = 443;
            }
            # No longer required now that SSH over AWS SCM is in use
            # {
            #   description = "Allow SSH";
            #   from_port = 22;
            #   to_port = 22;
            # }
          ];

          egress = map mkSecurityGroupRule [
            {
              description = "Allow outbound traffic";
              from_port = 0;
              to_port = 0;
              protocol = "-1";
            }
          ];

          tags = defaultTags;
        };
      });

      local_file.ssh_config = {
        filename = "\${path.module}/.ssh_config";
        file_permission = "0600";
        content = ''
          Host *
            User root
            UserKnownHostsFile /dev/null
            StrictHostKeyChecking no
            ServerAliveCountMax 2
            ServerAliveInterval 60

          ${
            concatStringsSep "\n" (map (name: ''
                Host ${name}
                  HostName ''${aws_instance.${name}[0].id}
                  ProxyCommand sh -c "aws --region ${nodes.${name}.aws.region} ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
                  Tag ${nodes.${name}.aws.instance.instance_type}

                Host ${name}.ipv4
                  HostName ''${aws_eip.${name}[0].public_ip}
                  Tag ${nodes.${name}.aws.region}
              '')
              (attrNames nodes))
          }
        '';
      };
    };

    data = {
      # Common parameters:
      #   data.aws_caller_identity.current.account_id
      #   data.aws_region.current.name
      aws_caller_identity.current = {};
      aws_region.current = {};
      aws_route53_zone.selected.name = "${aws.domain}.";

      aws_ami = mapRegions ({region, ...}: {
        "nixos_${underscore monitorSystem}_${underscore region}" = {
          owners = ["427812963091"];
          most_recent = true;
          provider = "aws.${region}";

          filter = [
            {
              name = "name";
              values = ["nixos/25.05*"];
            }
            {
              name = "architecture";
              values = [(head (splitString "-" monitorSystem))];
            }
          ];
        };
      });

      # Ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
      aws_availability_zones = mapRegions ({region, ...}: {
        ${region} = {
          provider = "aws.${region}";
          filter = [
            {
              name = "opt-in-status";
              values = ["opt-in-not-required"];
            }
          ];
        };
      });

      aws_iam_policy_document = mapBuckets (bucket: {
        name = "allow_${bucket}";
        value = {
          statement = {
            principals = {
              type = "AWS";
              identifiers = ["\${aws_iam_role.ec2_role.arn}"];
            };

            actions = ["s3:*"];

            resources = [
              "\${data.aws_s3_bucket.${bucket}.arn}"
              "\${data.aws_s3_bucket.${bucket}.arn}/*"
            ];
          };
        };
      });

      aws_internet_gateway = mapRegions ({region, ...}: {
        ${region} = {
          provider = "aws.${region}";
          filter = [
            {
              name = "attachment.vpc-id";
              values = ["\${data.aws_vpc.${region}.id}"];
            }
          ];
          depends_on = ["data.aws_vpc.${region}"];
        };
      });

      aws_route_table = mapRegions ({region, ...}: {
        ${region} = {
          provider = "aws.${region}";
          route_table_id = "\${data.aws_vpc.${region}.main_route_table_id}";
          depends_on = ["data.aws_vpc.${region}"];
        };
      });

      aws_s3_bucket = mapBuckets (bucket: {
        name = bucket;
        value = {inherit bucket;};
      });

      aws_subnet = mapRegions ({region, ...}: {
        ${region} = {
          provider = "aws.${region}";
          # The index of the map is used to assign an ipv6 subnet network
          # id offset in the aws_default_subnet ipv6_cidr_block resource
          # arg.
          #
          # While az ids are consistent across aws orgs, they are not
          # implemented in all regions, therefore we'll use az names as
          # indexed values.
          #
          # Ref:
          #   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet#availability_zone_id
          #
          for_each = "\${{for i, az in data.aws_availability_zones.${region}.names : i => az}}";
          availability_zone = "\${element(data.aws_availability_zones.${region}.names, each.key)}";
          default_for_az = true;
        };
      });

      aws_vpc = mapRegions ({region, ...}: {
        ${region} = {
          provider = "aws.${region}";
          default = true;
        };
      });
    };

    # Debug output
    # output =
    #   mapRegions ({region, ...}: {
    #     "aws_availability_zones_${region}".value = "\${data.aws_availability_zones.${region}.names}";
    #   })
    #   // mapRegions ({region, ...}: {
    #     "aws_internet_gateway_${region}".value = "\${data.aws_internet_gateway.${region}}";
    #   })
    #   // mapRegions ({region, ...}: {
    #     "aws_route_table_${region}".value = "\${data.aws_route_table.${region}}";
    #   })
    #   // mapRegions ({region, ...}: {
    #     "aws_subnet_${region}".value = "\${data.aws_subnet.${region}}";
    #   })
    #   // mapRegions ({region, ...}: {
    #     "aws_vpc_${region}".value = "\${data.aws_vpc.${region}}";
    #   });
  };
in {
  flake.opentofu.cluster = inputs.terranix.lib.terranixConfiguration {
    system = deploySystem;
    modules = [allConfig];
  };
}
