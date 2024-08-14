{self, ...}: {
  perSystem = {
    pkgs,
    self',
    config,
    inputs',
    ...
  }: {
    # The shell you get when running `nix develop`.
    # We recommend using https://direnv.net for better integration with your
    # shell, since you will be forced to use Bash instead.
    # Once you have direnv installed and change into a directory within this
    # repository, you will be able to run `direnv allow` to get all rquired
    # environment variables set.
    devShells.default = pkgs.mkShell {
      # packages that will be available within the devShell
      packages =
        (with pkgs; [
          # Interact with AWS, used by many tasks in the Justfile
          awscli2
          # Used for `caddy hash-password` to provision Basic Auth
          caddy
          # Deploying NixOS
          colmena
          # Formatting code
          config.treefmt.build.wrapper
          # Used by `just lint`
          deadnix
          # Our task runner, see the Justfile
          just
          # Used for generating a documentation page
          mdbook
          # Bootstrap Mimir alertmanager, see `mimir-bootstrap` in Justfile
          mimir
          # Mostly for the handy `sponge` command
          moreutils
          # Used for most scripts in the Justfile
          nushellFull
          # Used for talking with CloudFormation
          rain
          # Encryption
          sops
          # Used by `just lint`
          statix
        ])
        ++ (with self'.packages; [
          # This is not in nixpkgs, but very handy for parsing the SSH config file
          # to extract information.
          # Used in the Justfile to list names and IPs
          ssh-config-json

          # OpenTofu with our required plugins and using the opentofu-registry
          opentofu

          # A wrapper around opentofu that ensures use of the right workspace,
          # generates configuration from Nix, and can set secrets via a
          # var-file.
          tf
        ]);

      # Some environment variables used by both OpenTofu and CloudFormation, as
      # well as SOPS and the AWS CLI.
      AWS_PROFILE = self.cluster.infra.aws.profile;
      AWS_REGION = self.cluster.infra.aws.region;

      # A handy shortcut for SOPS, so you can use `sops --kms $KMS` to encrypt
      # secrets.
      KMS = self.cluster.infra.aws.kms;

      # This variable is used by colmena, so we can refer to machines without
      # DNS or hardcoding IPs.
      # The file is generated by OpenTofu when running `just tf cluster`.
      SSH_CONFIG_FILE = ".ssh_config";

      # The shellHook is run every time you enter the devshell.
      # Linking the treefmt.toml to the toplevel of the repository allows
      # running `treefmt` without any flags.
      shellHook = ''
        ln -sf ${config.treefmt.build.configFile} treefmt.toml
      '';
    };
  };
}
