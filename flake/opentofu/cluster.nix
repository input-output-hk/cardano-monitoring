{
  self,
  inputs,
  lib,
  config,
  ...
}: let
  inherit (self.cluster.infra) generic aws;

  amis = import "${inputs.nixpkgs}/nixos/modules/virtualisation/amazon-ec2-amis.nix";
  awsProviderFor = region: "aws.${underscore region}";
  underscore = lib.replaceStrings ["-"] ["_"];

  nixosConfigurations = lib.mapAttrs (_: node: node.config) config.flake.nixosConfigurations;
  nodes = lib.filterAttrs (_: node: node.aws != null && node.aws.instance.count > 0) nixosConfigurations;
  mapNodes = f: lib.mapAttrs f nodes;

  regions =
    lib.mapAttrsToList (region: enabled: {
      region = underscore region;
      count =
        if enabled
        then 1
        else 0;
    })
    aws.regions;

  buckets = builtins.attrValues (lib.filterAttrs (name: _: name != "state") aws.buckets);

  mapRegions = f: builtins.foldl' lib.recursiveUpdate {} (lib.forEach regions f);
in {
  flake.opentofu.cluster = inputs.terranix.lib.terranixConfiguration {
    system = "x86_64-linux";
    modules = [
      {
        terraform = {
          required_providers = {
            aws.source = "opentofu/aws";
            null.source = "opentofu/null";
            local.source = "opentofu/local";
            tls.source = "opentofu/tls";
          };

          backend = {
            s3 = {
              inherit (aws) region;
              bucket = aws.buckets.state;
              key = "opentofu";
              dynamodb_table = "opentofu";
            };
          };
        };

        provider.aws = lib.forEach (builtins.attrNames aws.regions) (region: {
          inherit region;
          alias = underscore region;
          default_tags.tags = {
            inherit (generic) organization tribe function repo;
            environment = "generic";
          };
        });

        resource = {
          aws_instance = mapNodes (
            _: node:
              {
                inherit (node.aws.instance) count instance_type;
                provider = awsProviderFor node.aws.region;
                ami = amis.${node.system.stateVersion}.${node.aws.region}.aarch64-linux.hvm-ebs;
                iam_instance_profile = "\${aws_iam_instance_profile.ec2_profile.name}";
                monitoring = true;
                key_name = "\${aws_key_pair.bootstrap_${underscore node.aws.region}[0].key_name}";
                vpc_security_group_ids = [
                  "\${aws_security_group.common_${underscore node.aws.region}[0].id}"
                ];
                inherit (node.aws.instance) tags;

                root_block_device = {
                  inherit (node.aws.instance.root_block_device) volume_size;
                  volume_type = "gp3";
                  iops = 3000;
                  delete_on_termination = true;
                };

                metadata_options = {
                  http_endpoint = "enabled";
                  http_put_response_hop_limit = 2;
                  http_tokens = "optional";
                };

                lifecycle = [{ignore_changes = ["ami" "user_data"];}];
              }
              // lib.optionalAttrs (node.aws.instance ? availability_zone) {
                inherit (node.aws.instance) availability_zone;
              }
          );

          aws_iam_instance_profile.ec2_profile = {
            name = "ec2Profile";
            role = "\${aws_iam_role.ec2_role.name}";
          };

          aws_iam_role.ec2_role = {
            name = "ec2Role";
            assume_role_policy = builtins.toJSON {
              Version = "2012-10-17";
              Statement = [
                {
                  Action = "sts:AssumeRole";
                  Effect = "Allow";
                  Principal.Service = "ec2.amazonaws.com";
                }
              ];
            };
          };

          aws_s3_bucket_policy = lib.listToAttrs (map (bucket: {
              name = "allow_${bucket}";
              value = {
                bucket = "\${data.aws_s3_bucket.${bucket}.id}";
                policy = "\${data.aws_iam_policy_document.allow_${bucket}.json}";
              };
            })
            buckets);

          aws_iam_role_policy_attachment = let
            mkRoleAttachments = roleResourceName: policyList:
              lib.listToAttrs (map (policy: {
                  name = "${roleResourceName}_policy_attachment_${policy}";
                  value = {
                    role = "\${aws_iam_role.${roleResourceName}.name}";
                    policy_arn = "\${aws_iam_policy.${policy}.arn}";
                  };
                })
                policyList);
          in
            builtins.foldl' lib.recursiveUpdate {} [
              (mkRoleAttachments "ec2_role" ["kms_user"])
            ];

          aws_iam_policy.kms_user = {
            name = "kmsUser";
            policy = builtins.toJSON {
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
          };

          aws_route53_record = mapNodes (
            nodeName: _: {
              zone_id = "\${data.aws_route53_zone.selected.zone_id}";
              name = "${nodeName}.\${data.aws_route53_zone.selected.name}";
              type = "A";
              ttl = "300";
              records = ["\${aws_eip.${nodeName}[0].public_ip}"];
            }
          );

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
            };
          });

          aws_eip = mapNodes (name: node: {
            inherit (node.aws.instance) count tags;
            provider = awsProviderFor node.aws.region;
            instance = "\${aws_instance.${name}[0].id}";
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
          aws_security_group = let
            mkRule = lib.recursiveUpdate {
              protocol = "tcp";
              cidr_blocks = ["0.0.0.0/0"];
              ipv6_cidr_blocks = ["::/0"];
              prefix_list_ids = [];
              security_groups = [];
              self = true;
            };
          in
            mapRegions ({
              region,
              count,
            }: {
              "common_${region}" = {
                inherit count;
                provider = awsProviderFor region;
                name = "common";
                description = "Allow common ports";
                lifecycle = [{create_before_destroy = true;}];

                ingress = [
                  (mkRule {
                    description = "Allow HTTP";
                    from_port = 80;
                    to_port = 80;
                  })
                  (mkRule {
                    description = "Allow HTTPS";
                    from_port = 443;
                    to_port = 443;
                  })
                  (mkRule {
                    description = "Allow SSH";
                    from_port = 22;
                    to_port = 22;
                  })
                  (mkRule {
                    description = "Allow Wireguard";
                    from_port = 51820;
                    to_port = 51820;
                    protocol = "udp";
                  })
                ];

                egress = [
                  (mkRule {
                    description = "Allow outbound traffic";
                    from_port = 0;
                    to_port = 0;
                    protocol = "-1";
                  })
                ];
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
                builtins.concatStringsSep "\n" (map (name: ''
                    Host ${name}
                      HostName ''${aws_eip.${name}[0].public_ip}
                  '')
                  (builtins.attrNames nodes))
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

          aws_s3_bucket = lib.listToAttrs (map (bucket: {
              name = bucket;
              value = {inherit bucket;};
            })
            buckets);

          aws_iam_policy_document = lib.listToAttrs (map (bucket: {
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
            })
            buckets);
        };
      }
    ];
  };
}
