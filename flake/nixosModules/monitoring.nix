parts: {
  # Here we specify what a monitoring machine should look like.
  flake.nixosModules.monitoring = {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    # First we get some required constants from our cluster.nix
    inherit (parts.config.flake.cluster.infra.aws) buckets domain email;

    # secrets that Grafana requires access to require the correct owner. We will
    # also restart grafana if any of them change.
    ownerGrafana = sopsFile: {
      inherit sopsFile;
      owner = "grafana";
      restartUnits = ["grafana.service"];
    };
  in {
    options.monitoring.subdomain = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = ''
        The subdomain to use.
        Set to «name» by default.
        This is useful when a project is still confidential
        so that the TLS certificate registration does not leak its name.
      '';
    };

    config = let
      cfg = config.monitoring;
    in {
      # SOPS is used for encrypting our secrets
      sops.secrets = {
        # The initial password for the administrator. This is used to bootstrap our
        # google oauth logins and give them the correct permissions.
        grafana-password = ownerGrafana ../../secrets/grafana-password.enc;

        # Obtained from https://console.cloud.google.com/apis/credentials
        # Note that we use the same OAuth credentials for all Grafana instances.
        grafana-oauth-client-id = ownerGrafana ../../secrets/grafana-oauth-client-id.enc;
        grafana-oauth-client-secret = ownerGrafana ../../secrets/grafana-oauth-client-secret.enc;

        # For each machine, we have separate Basic Auth credentials.
        # These are used for provisioning via OpenTofu from other repositories.
        # We also have to ensure Caddy is restarted once the file changes.
        caddy-environment = {
          sopsFile = ../../secrets + "/caddy-environment-${name}.enc";
          restartUnits = ["caddy.service"];
        };
      };

      # Allow HTTP (for obtaining the ACME certificate) and HTTPS.
      networking.firewall.allowedTCPPorts = [80 443];

      systemd.services = {
        # There is no existing NixOS option to set secrets for Caddy easily, so we
        # just inject them into the environment.
        # Within the Caddy configuration we can then reference them like:
        # {$ADMIN_HASH}
        caddy.serviceConfig.EnvironmentFile = config.sops.secrets.caddy-environment.path;

        # Avoid grafana failing on reboot due to a secrets utilization race
        # condition.
        grafana.preStart = ''
          while ! [ -f ${config.sops.secrets.grafana-password.path} ]; do
            echo "Waiting for grafana secrets to become available..."
            sleep 5
          done
        '';

        # Avoid mimir failing on reboot due to a network interface not yet being
        # available when it tries to bind.
        mimir = {
          # Using WantedBy and After for networking.target don't help, so we'll
          # adjust the retry parameters to avoid failure.
          startLimitIntervalSec = 10;
          startLimitBurst = 10;

          serviceConfig = {
            Restart = "always";
            RestartSec = "10s";
          };
        };
      };

      # Finally all the services that need to be started.
      services = {
        # Grafana provides us with Dashboards and a nice interface to query metrics.
        grafana = {
          enable = true;

          settings = {
            # We use AlertManager instead of the built-in functionality. It
            # provides us with a better way to provision alerts with complex
            # queries and they won't be tied to dashboards or a separate database.
            alerting.enabled = false;

            # Don't phone home.
            analytics.reporting_enabled = false;

            # We only allow people with Google accounts and the bootstrap admin.
            "auth.anonymous".enabled = false;

            # The password used for bootstrapping.
            security.admin_password = "$__file{${config.sops.secrets.grafana-password.path}}";

            # Provides a nicer view of all the alerts including the ones from AlertManager.
            unified_alerting.enabled = true;

            # We want users to be able to create their own dashboards by default.
            users.auto_assign_org_role = "Editor";

            server = {
              domain = "${cfg.subdomain}.${domain}";
              root_url = "https://${config.services.grafana.settings.server.domain}/";

              # Traffic is compressed by Caddy.
              enable_gzip = false;

              # Redirect to correct domain if the host header does not match the
              # domain. Prevents DNS rebinding attacks.
              enforce_domain = true;
            };

            "auth.google" = {
              enabled = true;
              allow_sign_up = true;
              auto_login = false;
              client_id = "$__file{${config.sops.secrets.grafana-oauth-client-id.path}}";
              client_secret = "$__file{${config.sops.secrets.grafana-oauth-client-secret.path}}";
              scopes = "openid email profile";
              auth_url = "https://accounts.google.com/o/oauth2/v2/auth";
              token_url = "https://oauth2.googleapis.com/token";
              api_url = "https://openidconnect.googleapis.com/v1/userinfo";
              allowed_domains = "iohk.io";
              hosted_domain = "iohk.io";
              use_pkce = true;
            };
          };

          provision = {
            enable = true;

            datasources.settings = {
              # Use this to get rid of already provisioned datasources
              # deleteDatasources = [
              #   {
              #     name = "Alertmanager (Mimir)";
              #     orgId = 1;
              #   }
              # ];

              datasources =
                [
                  {
                    type = "prometheus";
                    name = "Mimir";
                    uid = "mimir";
                    isDefault = true;
                    url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/prometheus";
                    jsonData.timeInterval = "60s";
                  }
                  {
                    type = "alertmanager";
                    name = "Alertmanager";
                    uid = "alertmanager_mimir";
                    url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir";
                    jsonData = {
                      implementation = "mimir";
                      handleGrafanaManagedAlerts = true;
                    };
                  }
                ]
                ++ lib.optional config.services.loki.enable {
                  type = "loki";
                  name = "Loki";
                  uid = "loki";
                  url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
                  jsonData.manageAlerts = true;
                };
            };
          };
        };

        mimir = {
          enable = true;

          configuration = {
            common.storage = {
              backend = "s3";
              s3 = {
                inherit (parts.config.flake.cluster.infra.aws) region;
                bucket_name = buckets.${name} or (throw "Missing S3 bucket for ${name}");
                endpoint = "s3.amazonaws.com";
              };
            };

            target = "all,alertmanager";

            blocks_storage.storage_prefix = "blocks";

            ruler.alertmanager_url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/alertmanager";

            limits.compactor_blocks_retention_period = "1y";

            compactor = {
              data_dir = "/tmp/mimir/compactor";
              sharding_ring.kvstore.store = "memberlist";
            };

            distributor = {
              ring = {
                instance_addr = "127.0.0.1";
                kvstore.store = "memberlist";
              };
            };

            ingester = {
              ring = {
                instance_addr = "127.0.0.1";
                kvstore.store = "memberlist";
                replication_factor = 1;
              };
            };

            multitenancy_enabled = false;

            # Allow ingestion of out-of-order samples up to 5 minutes since the latest received sample for the series.
            limits.out_of_order_time_window = "5m";

            # Help prevent "too many outstanding requests" errors.
            frontend.max_outstanding_per_tenant = 256; # Default is 100

            server = {
              http_listen_port = 8080;
              http_listen_address = "127.0.0.1";
              # log_level = "debug";
              http_path_prefix = "/mimir";
              log_request_headers = true;
            };

            store_gateway.sharding_ring.replication_factor = 1;

            usage_stats.enabled = false;

            alertmanager = {
              external_url = "https://${cfg.subdomain}.${domain}/mimir/alertmanager";
              data_dir = "/var/lib/mimir/alertmanager";
              # Alertmanager won't start with an empty configuration, so we make a dummy one.
              fallback_config_file = pkgs.writeText "alertmanager-fallback-config.yaml" (builtins.toJSON {
                route = {
                  group_wait = "0s";
                  receiver = "empty-receiver";
                };
                receivers = [{name = "empty-receiver";}];
              });
            };
          };
        };

        caddy = {
          enable = true;
          enableReload = true;
          inherit email;

          virtualHosts."${cfg.subdomain}.${domain}".extraConfig =
            ''
              encode zstd gzip

              handle /blackbox/* {
                basicauth { admin {$ADMIN_HASH} }
                reverse_proxy 127.0.0.1:9115
              }

              handle /mimir/api/v1/push {
                basicauth { write {$WRITE_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}
              }

              handle /mimir/* {
                basicauth { admin {$ADMIN_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}
              }
            ''
            + lib.optionalString config.services.loki.enable ''
              handle /loki/api/v1/push {
                basicauth { write {$WRITE_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              }

              handle /loki/* {
                basicauth { admin {$ADMIN_HASH} }
                uri strip_prefix /loki
                reverse_proxy 127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              }

              handle /otlp/v1/logs {
                basicauth { write {$WRITE_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              }
            ''
            + ''
              handle /* {
                reverse_proxy 127.0.0.1:${toString config.services.grafana.settings.server.http_port}
              }
            '';
        };

        prometheus = {
          enable = true;
          # extraFlags = ["--log.level=debug"];

          alertmanagers = [
            {
              scheme = "http";
              path_prefix = "/mimir";
              static_configs = [{targets = ["127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}"];}];
            }
          ];

          exporters.blackbox = {
            enable = true;
            extraFlags = [
              # "--web.external-url=https://${cfg.subdomain}.${domain}/blackbox"
              # "--web.route-prefix=/blackbox"
              # "--log.level=debug"
            ];
            configFile = pkgs.writeText "blackbox-exporter.json" (builtins.toJSON {
              modules.https_2xx = {
                prober = "http";
                timeout = "5s";
                http.fail_if_not_ssl = true;
                http.preferred_ip_protocol = "ip4";
              };
            });
          };
        };

        loki.configuration = {
          auth_enabled = false;

          limits_config.retention_period = "24h";

          common = {
            ring.kvstore.store = "inmemory";
            replication_factor = 1;
          };

          server = {
            http_listen_port = 3100;
            grpc_listen_port = 3101;
          };

          compactor = {
            working_directory = "/var/lib/loki/compactor";
            compaction_interval = "10m";
            retention_enabled = true;
            retention_delete_delay = "2h";
            retention_delete_worker_count = 150;
            delete_request_store = "s3";
          };

          storage_config = {
            tsdb_shipper = {
              active_index_directory = "/var/lib/loki/index/active";
              cache_location = "/var/lib/loki/index/cache";
            };

            aws = {
              s3 = "s3://${parts.config.flake.cluster.infra.aws.region}";
              bucketnames = buckets."${name}Loki" or (throw "Missing S3 bucket for ${name}Loki");
            };
          };

          schema_config.configs = [
            {
              from = "2024-07-16";
              store = "tsdb";
              object_store = "s3";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];

          ruler = {
            alertmanager_url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/alertmanager";
            storage = {
              type = "s3";
              s3 = {
                s3 = "s3://${parts.config.flake.cluster.infra.aws.region}";
                bucketnames = buckets."${name}Loki" or (throw "Missing S3 bucket for ${name}Loki");
              };
            };
            rule_path = "/var/lib/loki/rules";
            ring.kvstore.store = "inmemory";
          };
        };
      };
    };
  };
}
