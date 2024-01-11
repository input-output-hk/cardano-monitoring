{self, ...}: {
  flake.nixosModules.monitoring = {
    config,
    pkgs,
    name,
    ...
  }: let
    inherit (self.cluster.infra.aws) bucketName domain email;

    ownerGrafana = sopsFile: {
      owner = "grafana";
      inherit sopsFile;
      restartUnits = ["grafana.service"];
    };
  in {
    sops.secrets.grafana-password = ownerGrafana ../../secrets/grafana-password.enc;
    sops.secrets.grafana-oauth-client-id = ownerGrafana ../../secrets/grafana-oauth-client-id.enc;
    sops.secrets.grafana-oauth-client-secret = ownerGrafana ../../secrets/grafana-oauth-client-secret.enc;
    sops.secrets."caddy-environment-${name}" = {
      sopsFile = ../../secrets + "/caddy-environment-${name}.enc";
      restartUnits = ["caddy.service"];
    };

    services.grafana = {
      enable = true;

      settings = {
        alerting.enabled = false;
        analytics.reporting_enabled = false;
        "auth.anonymous".enabled = false;
        security.admin_password = "$__file{${config.sops.secrets.grafana-password.path}}";
        unified_alerting.enabled = true;
        server = {
          domain = "${name}.${domain}";
          root_url = "https://${name}.${domain}/";
          enable_gzip = true;
          enforce_domain = true;
        };
        users.auto_assign_org_role = "Editor";
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

          datasources = [
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
          ];
        };
      };
    };

    services.mimir = {
      enable = true;

      configuration = {
        common.storage = {
          backend = "s3";
          s3 = {
            region = self.cluster.infra.aws.region;
            bucket_name = "${bucketName}-${name}";
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
          external_url = "https://${name}.${domain}/mimir/alertmanager";
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

    networking.firewall.allowedTCPPorts = [80 443];

    systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.secrets."caddy-environment-${name}".path;

    services.caddy = {
      enable = true;
      enableReload = true;
      inherit email;

      virtualHosts."${name}.${domain}".extraConfig = ''
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

        handle /* {
          reverse_proxy 127.0.0.1:${toString config.services.grafana.settings.server.http_port}
        }
      '';
    };

    services.prometheus = {
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
          # "--web.external-url=https://${name}.${domain}/blackbox"
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
  };
}
