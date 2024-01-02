{self, ...}: {
  perSystem = {
    pkgs,
    self',
    config,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages =
        [config.treefmt.build.wrapper]
        ++ (with pkgs; [
          awscli2
          colmena
          deadnix
          just
          rain
          statix
          moreutils
          ripgrep
          nushell
          sops
          grafana
          mimir
          caddy
        ])
        ++ (with self'.packages; [
          ssh-config-json
          opentofu
          tf
        ]);

      AWS_PROFILE = self.cluster.infra.aws.profile;
      AWS_REGION = self.cluster.infra.aws.region;
      KMS = self.cluster.infra.aws.kms;
      SSH_CONFIG_FILE = ".ssh_config";

      shellHook = ''
        ln -sf ${config.treefmt.build.configFile} treefmt.toml
      '';
    };
  };
}
