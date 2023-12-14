{
  inputs,
  lib,
  config,
  ...
}: let
  infra = config.flake.cluster.infra;
  inherit (infra.grafana) stackName;

  alertFileList = parseDir ./grafana/alerts ".nix-import";
  dashboardFileList = parseDir ./grafana/dashboards ".json";

  extractFileName = file:
    lib.pipe file [
      builtins.unsafeDiscardStringContext
      (lib.splitString "/")
      lib.last
      (lib.splitString ".")
      lib.head
      (lib.replaceStrings ["-"] ["_"])
    ];

  parseDir = dirPath: suffix:
    lib.mapAttrsToList (
      n: _: "${dirPath}/${n}"
    ) (lib.filterAttrs (n: v: lib.hasSuffix suffix n && v == "regular") (builtins.readDir dirPath));

  withGrafanaStack = attrs: attrs // {provider = "grafana.${stackName}";};

  sensitiveString = {
    type = "string";
    sensitive = true;
    nullable = false;
  };
in {
  flake.opentofu.grafana = inputs.terranix.lib.terranixConfiguration {
    system = "x86_64-linux";
    modules = [
      {
        terraform = {
          required_providers = {
            grafana.source = "grafana/grafana";
            mimir.source = "fgouteroux/mimir";
          };

          backend = {
            s3 = {
              inherit (infra.aws) region;
              bucket = infra.aws.bucketName;
              key = "opentofu";
              dynamodb_table = "opentofu";
            };
          };
        };

        variable = {
          deadmanssnitch_api_url = sensitiveString;
          grafana_token = sensitiveString;
          pagerduty_api_key = sensitiveString;
          mimir_api_key = sensitiveString;

          mimir_alertmanager_ruler_uri = sensitiveString;
          mimir_alertmanager_alertmanager_uri = sensitiveString;
          mimir_alertmanager_username = sensitiveString;

          mimir_prometheus_ruler_uri = sensitiveString;
          mimir_prometheus_alertmanager_uri = sensitiveString;
          mimir_prometheus_username = sensitiveString;
        };

        provider = {
          grafana = [
            {
              alias = stackName;
              url = "https://playground.${infra.aws.domain}/";
              auth = "\${var.grafana_token}";
            }
          ];

          mimir = [
            {
              alias = "prometheus";
              ruler_uri = "\${var.mimir_prometheus_ruler_uri}";
              alertmanager_uri = "\${var.mimir_prometheus_alertmanager_uri}";
              org_id = "1";
              username = "\${var.mimir_prometheus_username}";
              password = "\${var.mimir_api_key}";
            }
            {
              alias = "alertmanager";
              ruler_uri = "\${var.mimir_alertmanager_ruler_uri}";
              alertmanager_uri = "\${var.mimir_alertmanager_alertmanager_uri}";
              org_id = "1";
              username = "\${var.mimir_alertmanager_username}";
              password = "\${var.mimir_api_key}";
            }
          ];
        };

        resource = {
          grafana_contact_point.pagerduty = withGrafanaStack {
            name = "pagerduty";
            pagerduty.integration_key = "\${var.pagerduty_api_key}";
          };

          grafana_notification_policy.policy = withGrafanaStack {
            contact_point = "\${grafana_contact_point.pagerduty.name}";

            # Disable grouping
            group_by = ["..."];
          };

          mimir_alertmanager_config.pagerduty = {
            provider = "mimir.alertmanager";

            route = [
              {
                receiver = "pagerduty";
                group_by = ["..."];
                group_wait = "30s";
                group_interval = "5m";
                repeat_interval = "1y";
                child_route = [
                  {
                    receiver = "deadmanssnitch";
                    matchers = [''alertname="DeadMansSnitch"''];
                    group_wait = "30s";
                    group_interval = "5m";
                    repeat_interval = "5m";
                  }
                ];
              }
            ];

            receiver = [
              {
                name = "pagerduty";
                pagerduty_configs.service_key = "\${var.pagerduty_api_key}";
              }
              {
                name = "deadmanssnitch";
                webhook_configs = {
                  send_resolved = false;
                  url = "\${var.deadmanssnitch_api_url}";
                };
              }
            ];
          };

          # Dashboards
          grafana_dashboard = lib.foldl' (acc: f:
            lib.recursiveUpdate acc {
              ${extractFileName f} = withGrafanaStack {config_json = lib.readFile f;};
            }) {}
          dashboardFileList;

          # Alerts
          mimir_rule_group_alerting = lib.foldl' (acc: f:
            lib.recursiveUpdate acc {
              ${extractFileName f} = (import f) // {provider = "mimir.prometheus";};
            }) {}
          alertFileList;
        };
      }
    ];
  };
}
