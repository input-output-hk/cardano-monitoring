{
  self,
  inputs,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.common = moduleWithSystem ({system}: {
    name,
    pkgs,
    lib,
    config,
    ...
  }: {
    deployment.targetHost = name;

    networking = {
      hostName = name;
      firewall = {
        enable = true;
        allowedTCPPorts = [22];
        allowedUDPPorts = [];
      };
    };

    time.timeZone = "UTC";
    i18n.supportedLocales = ["en_US.UTF-8/UTF-8" "en_US/ISO-8859-1"];

    boot = {
      tmp.cleanOnBoot = true;
      kernelParams = ["boot.trace"];
      loader.grub.configurationLimit = 10;
    };

    documentation = {
      nixos.enable = false;
      man.man-db.enable = false;
      info.enable = false;
      doc.enable = false;
    };

    environment.systemPackages = with pkgs; [
      awscli2
      bat
      bind
      cloud-utils
      di
      dnsutils
      fd
      fx
      file
      git
      glances
      helix
      htop
      ijq
      icdiff
      iptables
      jiq
      jq
      lsof
      nano
      neovim
      ncdu
      parted
      pciutils
      procps
      ripgrep
      rsync
      sops
      sysstat
      tcpdump
      tree
    ];

    sops.defaultSopsFormat = "binary";

    sops.secrets.github-token = {
      sopsFile = "${self}/secrets/github-token.enc";
      owner = config.programs.auth-keys-hub.user;
      inherit (config.programs.auth-keys-hub) group;
    };

    programs = {
      auth-keys-hub = {
        enable = true;
        package = inputs.auth-keys-hub.packages.${system}.auth-keys-hub;
        dataDir = "/var/lib/auth-keys-hub";
        github = {
          teams = ["input-output-hk/node-sre"];
          users = ["manveru" "johnalotoski"];
          tokenFile = config.sops.secrets.github-token.path;
        };
      };

      tmux = {
        enable = true;
        aggressiveResize = true;
        clock24 = true;
        escapeTime = 0;
        historyLimit = 10000;
        newSession = true;
      };
    };

    services = {
      chrony = {
        enable = true;
        extraConfig = "rtcsync";
        enableRTCTrimming = false;
      };

      cron.enable = true;
      fail2ban.enable = true;

      openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          RequiredRSASize = 2048;
          PubkeyAcceptedAlgorithms = "-*nist*";
        };
      };

      grafana-agent = {
        enable = true;
        extraFlags = ["-disable-reporting"];
        settings = {
          integrations = {
            prometheus_remote_write = [{url = "http://127.0.0.1:8080/mimir/api/v1/push";}];
            node_exporter = {
              set_collectors = [
                "boottime"
                "conntrack"
                "cpu"
                "diskstats"
                "filefd"
                "filesystem"
                "loadavg"
                "meminfo"
                "netdev"
                "netstat"
                "os"
                "sockstat"
                "softnet"
                "stat"
                "time"
                "timex"
                "uname"
                "vmstat"
              ];
            };
          };

          metrics = {
            configs = [
              {
                name = "integrations";
                remote_write = [{url = "http://127.0.0.1:8080/mimir/api/v1/push";}];
                scrape_configs = [
                  {
                    job_name = "blackbox";
                    metrics_path = "/probe";
                    params.module = ["https_2xx"];
                    scrape_interval = "1m";
                    static_configs = [
                      {
                        targets = import ((inputs."cardano-${name}") + "/flake/terraform/grafana/blackbox/blackbox.nix-import");
                      }
                    ];
                    relabel_configs = [
                      {
                        source_labels = ["__address__"];
                        target_label = "__param_target";
                      }
                      {
                        source_labels = ["__param_target"];
                        target_label = "instance";
                      }
                      {
                        replacement = "127.0.0.1:9115";
                        target_label = "__address__";
                      }
                    ];
                  }
                  {
                    job_name = "prometheus";
                    scheme = "http";
                    static_configs = [
                      {
                        targets = ["${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}"];
                      }
                    ];
                    metrics_path = "/metrics";
                  }
                  {
                    job_name = "mimir";
                    scheme = "http";
                    static_configs = [
                      {
                        targets = ["${config.services.mimir.configuration.server.http_listen_address}:${toString config.services.mimir.configuration.server.http_listen_port}"];
                      }
                    ];
                    metrics_path = "/mimir/metrics";
                  }
                  {
                    job_name = "grafana";
                    scheme = "http";
                    static_configs = [
                      {
                        targets = ["${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}"];
                      }
                    ];
                    metrics_path = "/metrics";
                  }
                ];
              }
            ];
          };
        };
      };
    };

    system.extraSystemBuilderCmds = ''
      ln -sv ${pkgs.path} $out/nixpkgs
    '';

    nix = {
      registry.nixpkgs.flake = inputs.nixpkgs;
      optimise.automatic = true;
      gc.automatic = true;

      settings = {
        auto-optimise-store = true;
        builders-use-substitutes = true;
        experimental-features = ["nix-command" "fetch-closure" "flakes" "cgroups"];
        keep-derivations = true;
        keep-outputs = true;
        max-jobs = "auto";
        show-trace = true;
        substituters = ["https://cache.iog.io"];
        system-features = ["recursive-nix" "nixos-test"];
        tarball-ttl = 60 * 60 * 72;
        trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
      };
    };

    security.tpm2 = {
      enable = true;
      pkcs11.enable = true;
    };

    hardware = {
      enableRedistributableFirmware = true;
    };

    system.stateVersion = "23.05";

    systemd = {
      services = {
        # Remove the bootstrap key after 1 week in favor of auth-keys-hub use
        remove-ssh-bootstrap-key = {
          wantedBy = ["multi-user.target"];
          after = ["network-online.target"];

          serviceConfig = {
            Type = "oneshot";

            ExecStart = lib.getExe (pkgs.writeShellApplication {
              name = "remove-ssh-bootstrap-key";
              runtimeInputs = with pkgs; [fd gnugrep gnused];
              text = ''
                if ! [ -f /root/.ssh/.bootstrap-key-removed ]; then
                  # Verify auth keys is properly hooked into sshd
                  if ! grep -q 'AuthorizedKeysCommand /etc/ssh/auth-keys-hub --user %u' /etc/ssh/sshd_config; then
                    echo "SSH daemon authorized keys command does not appear to have auth-keys-hub installed"
                    exit
                  fi

                  if ! grep -q 'AuthorizedKeysCommandUser ${config.programs.auth-keys-hub.user}' /etc/ssh/sshd_config; then
                    echo "SSH daemon authorized keys command user does not appear to be using the ${config.programs.auth-keys-hub.user} user"
                    exit
                  fi

                  # Ensure at least 1 ssh key is declared outside of auth-keys-hub
                  if ! grep -q -E '^ssh-' /etc/ssh/authorized_keys.d/root &> /dev/null; then
                    echo "You must declare at least 1 authorized key via users.users.root.openssh.authorizedKeys attribute before the bootstrap key will be removed"
                    exit
                  fi

                  # Allow 1 week of bootstrap key use before removing it
                  if fd --quiet --changed-within 7d authorized_keys /root/.ssh; then
                    echo "The root authorized_keys file has been changed within the past week; waiting a little longer before removing the bootstrap key"
                    exit
                  fi

                  # Remove the bootstrap key and set a marker
                  echo "Removing the bootstrap key from /root/.ssh/authorized_keys"
                  sed -i '/bootstrap/d' /root/.ssh/authorized_keys
                  touch /root/.ssh/.bootstrap-key-removed
                fi
              '';
            });
          };
        };
      };

      timers = {
        remove-ssh-bootstrap-key = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "daily";
            Unit = "remove-ssh-bootstrap-key.service";
          };
        };

        # Enforce accurate 10 second sysstat sampling intervals
        sysstat-collect.timerConfig.AccuracySec = "1us";
      };
    };
  });
}
