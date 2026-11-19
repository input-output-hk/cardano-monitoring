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

    options.monitoring.externalUsers = {
      enable = lib.mkEnableOption ''
        a second Google sign-in button for people outside iohk.io, provided
        they are on this machine's editorsFile or viewersFile list, or on
        adminsFile with allowAdmins. Signing in with Google alone gets
        nobody in'';

      editorsFile = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets + "/grafana-external-editors-${name}.enc";
        description = ''
          This machine's SOPS file containing a JSON array of the external
          email addresses that get the Editor role, e.g. ["alice@example.com"].
          "*@example.com" matches every address at example.com, provided the
          account belongs to that domain's Google organisation.
          Use [] for none.
        '';
      };

      viewersFile = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets + "/grafana-external-viewers-${name}.enc";
        description = ''
          This machine's SOPS file containing a JSON array of the external
          email addresses that get the Viewer role, e.g. ["bob@example.com"].
          "*@example.com" works as for editorsFile.
          Use [] for none.
        '';
      };

      allowAdmins = lib.mkEnableOption ''
        the org Admin role for the addresses in adminsFile.
        Off by default, so that nobody from outside gets Admin'';

      adminsFile = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets/grafana-external-admins.enc;
        description = ''
          SOPS file containing a JSON array of the external email addresses
          that get the org Admin role on machines that set allowAdmins, e.g.
          ["carol@example.com"]. Shared by those machines and meant for the
          SRE team. Exact addresses only: "*@" entries are ignored here.
          Admins can invite password users and create API tokens, neither of
          which the lists control.
        '';
      };
    };

    options.monitoring.grafanaSecretKeyRotated = lib.mkEnableOption ''
      Grafana's own secret_key, from this machine's
      secrets/grafana-secret-key-«name».enc, instead of Grafana's public
      default. The key encrypts the secrets Grafana keeps in its database,
      so a new machine can set this from its first deploy, but any other
      only once grafana-rekey has re-encrypted its database (see
      docs/grafana-secret-key.md). Otherwise those secrets become
      unreadable'';

    config = let
      cfg = config.monitoring;
      secretKey = "$__file{${config.sops.secrets.grafana-secret-key.path}}";
    in {
      # SOPS is used for encrypting our secrets
      sops.secrets = {
        # The initial password for the administrator. This is used to bootstrap our
        # google oauth logins and give them the correct permissions.
        grafana-password = ownerGrafana ../../secrets/grafana-password.enc;

        # Grafana's secret_key, which encrypts the secrets Grafana keeps in its
        # database. Installed even before monitoring.grafanaSecretKeyRotated is
        # set, so that grafana-rekey can re-encrypt the database for it.
        grafana-secret-key = ownerGrafana (../../secrets + "/grafana-secret-key-${name}.enc");

        # Obtained from https://console.cloud.google.com/apis/credentials
        # Note that we use the same OAuth credentials for all Grafana instances.
        grafana-oauth-client-id = ownerGrafana ../../secrets/grafana-oauth-client-id.enc;
        grafana-oauth-client-secret = ownerGrafana ../../secrets/grafana-oauth-client-secret.enc;

        # The external Google sign-in, see monitoring.externalUsers: who may use
        # it, and its OAuth client, which belongs to the external organisation.
        grafana-external-editors = lib.mkIf cfg.externalUsers.enable (ownerGrafana cfg.externalUsers.editorsFile);
        grafana-external-viewers = lib.mkIf cfg.externalUsers.enable (ownerGrafana cfg.externalUsers.viewersFile);
        grafana-external-admins = lib.mkIf (cfg.externalUsers.enable && cfg.externalUsers.allowAdmins) (ownerGrafana cfg.externalUsers.adminsFile);
        grafana-external-oauth-client-id = lib.mkIf cfg.externalUsers.enable (ownerGrafana ../../secrets/grafana-external-oauth-client-id.enc);
        grafana-external-oauth-client-secret = lib.mkIf cfg.externalUsers.enable (ownerGrafana ../../secrets/grafana-external-oauth-client-secret.enc);

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

      # Re-encrypts Grafana's database for a new secret_key, see
      # monitoring.grafanaSecretKeyRotated.
      environment.systemPackages = [
        parts.config.flake.packages.${pkgs.stdenv.hostPlatform.system}.grafana-rekey
      ];

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

            # Encrypts the secrets Grafana keeps in its database. Until
            # monitoring.grafanaSecretKeyRotated is set, this is Grafana's
            # public default, which NixOS 26.05 no longer sets for us.
            security.secret_key =
              if cfg.grafanaSecretKeyRotated
              then secretKey
              else "SW2YcwTIb9zpOOhoPsMm";

            # Grafana 13's secrets manager has its own copy of the key, which
            # defaults to the same public value.
            "secrets_manager.encryption.secret_key.v1" = lib.mkIf cfg.grafanaSecretKeyRotated {
              secret_key = secretKey;
            };

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

              # Tell the two Google buttons apart on the login page.
              name = lib.mkIf cfg.externalUsers.enable "Google (Input Output users)";
            };

            # A second Google sign-in for people outside iohk.io, provided
            # they are on the allow-lists set by monitoring.externalUsers:
            # the lists, not the Google sign-in, are what grant access. The
            # client above is Internal to iohk.io, so this one uses a separate
            # External OAuth client, owned by an external organisation, that
            # any Google account can use, unless its Workspace admins block
            # third-party apps. The lists work through Grafana's role sync,
            # which sets a user's role from them at every sign-in. Role sync
            # is off for the iohk.io login above, where roles are managed by
            # hand in Grafana, and turning it on there would overwrite them.
            # So external users get this separate provider, and role sync
            # only applies to them.
            "auth.generic_oauth" = lib.mkIf cfg.externalUsers.enable (let
              # The secrets hold JSON arrays. Backticks make them JMESPath
              # literals, so that an empty [] works too. to_array keeps the
              # match exact if a malformed list is ever read as one string.
              emails = secret: "to_array(`$__file{${config.sops.secrets.${secret}.path}}`)";
              listed = secret: "contains(${emails secret}, email)";

              # Also matches a "*@<domain>" entry for the address's domain, but
              # only for accounts managed by a Google organisation (hd), which
              # has to own the domain of every address it issues. hd itself
              # may name another of its domains, so it isn't compared. Personal
              # accounts don't count here: they keep working after the person
              # leaves, and nobody would know to remove them. split and lower
              # come from Grafana's JMESPath library (jmespath-community).
              listedOrDomain = secret: "(${listed secret} || hd && contains(${emails secret}, join('', ['*@', lower(split(email, '@')[-1])])))";

              # Highest role first, so that someone on several lists gets the
              # highest of them.
              roles =
                lib.optional cfg.externalUsers.allowAdmins "${listed "grafana-external-admins"} && 'Admin'"
                ++ [
                  "${listedOrDomain "grafana-external-editors"} && 'Editor'"
                  "${listedOrDomain "grafana-external-viewers"} && 'Viewer'"
                ];
            in {
              enabled = true;
              name = "Google (others)";
              icon = "google";
              allow_sign_up = true;
              auto_login = false;
              client_id = "$__file{${config.sops.secrets.grafana-external-oauth-client-id.path}}";
              client_secret = "$__file{${config.sops.secrets.grafana-external-oauth-client-secret.path}}";
              scopes = "openid email profile";
              auth_url = "https://accounts.google.com/o/oauth2/v2/auth";
              token_url = "https://oauth2.googleapis.com/token";
              api_url = "https://openidconnect.googleapis.com/v1/userinfo";
              use_pkce = true;

              # Unlike auth.google, this provider doesn't check email_verified,
              # so we do it here. Exact addresses accept any Google account,
              # including a personal one created with a work address, so that
              # people whose company doesn't use Google can be listed too.
              role_attribute_path = "email_verified && (${lib.concatStringsSep " || " roles}) || ''";

              # This is what enforces the lists: anyone on none of them is
              # refused after the Google sign-in, before a Grafana user is
              # created. It only takes effect with role sync on: the default
              # for generic_oauth, but not for auth.google, so we set it
              # explicitly.
              role_attribute_strict = true;
              skip_org_role_sync = false;
            });
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
            query_scheduler.max_outstanding_requests_per_tenant = 256; # Default is 100

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
                basic_auth { admin {$ADMIN_HASH} }
                reverse_proxy 127.0.0.1:9115
              }

              handle /mimir/api/v1/push {
                basic_auth { write {$WRITE_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}
              }

              handle /mimir/* {
                basic_auth { admin {$ADMIN_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}
              }
            ''
            + lib.optionalString config.services.loki.enable ''
              handle /loki/api/v1/push {
                basic_auth { write {$WRITE_HASH} }
                reverse_proxy 127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              }

              handle /loki/* {
                basic_auth { admin {$ADMIN_HASH} }
                uri strip_prefix /loki
                reverse_proxy 127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}
              }

              handle /otlp/v1/logs {
                basic_auth { write {$WRITE_HASH} }
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

            # Recording rules land in mimir beside its own, so a log-derived
            # number costs one rule file instead of a log scan per dashboard draw.
            remote_write = {
              enabled = true;
              clients.mimir.url = "http://127.0.0.1:${toString config.services.mimir.configuration.server.http_listen_port}/mimir/api/v1/push";
            };
            wal.dir = "/var/lib/loki/ruler-wal";
          };
        };
      };
    };
  };
}
