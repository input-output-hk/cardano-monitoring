{
  self,
  inputs,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.common = moduleWithSystem ({system}: {
    name,
    pkgs,
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
      age
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

    # Sops-secrets service provides a systemd hook for other services
    # needing to be restarted after new secrets are pushed.
    #
    # Example usage:
    #   systemd.services.<name> = {
    #     after = ["sops-secrets.service"];
    #     wants = ["sops-secrets.service"];
    #     partOf = ["sops-secrets.service"];
    #   };
    #
    # Also, on boot SOPS runs in stage 2 without networking.
    # For repositories using KMS sops secrets, this prevent KMS from working,
    # so we repeat the activation script until decryption succeeds.
    systemd.services.sops-secrets = {
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];

      script = config.system.activationScripts.setupSecrets.text or "true";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

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
          users = ["manveru"];
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

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCogRPMTKyOIQcbS/DqbYijPrreltBHf5ctqFOVAlehvpj8enEE51VSjj4Xs/JEsPWpOJL7Ldp6lDNgFzyuL2AOUWE7wlHx2HrfeCOVkPEzC3uL4OjRTCdsNoleM3Ny2/Qxb0eX2SPoSsEGvpwvTMfUapEa1Ak7Gf39voTYOucoM/lIB/P7MKYkEYiaYaZBcTwjxZa3E+v7At4umSZzv8x24NV60fAyyYmt5hVZRYgoMW+nTU4J/Oq9JGgY7o+WPsOWcgFoSretRnGDwjM1IAUFVpI45rQH2HTKNJ6Bp6ncKwtVaP2dvPdBFe3x2LLEhmh1jDwmbtSXfoVZxbONtub2i/D8DuDhLUNBx/ROgal7N2RgYPcPuNdzfp8hMPjPGZVcSmszC/J1Gz5LqLfWbKKKti4NiSX+euy+aYlgW8zQlUS7aGxzRC/JSgk2KJynFEKJjhj7L9KzsE8ysIgggxYdk18ozDxz2FMPMV5PD1+8x4anWyfda6WR8CXfHlshTwhe+BkgSbsYNe6wZRDGqL2no/PY+GTYRNLgzN721Nv99htIccJoOxeTcs329CppqRNFeDeJkGOnJGc41ze+eVNUkYxOP0O+pNwT7zNDKwRwBnT44F0nNwRByzj2z8i6/deNPmu2sd9IZie8KCygqFiqZ8LjlWTD6JAXPKtTo5GHNQ== john.lotoski@iohk.io"
    ];

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
  });
}
