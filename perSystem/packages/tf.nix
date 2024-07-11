{
  perSystem = {
    self',
    pkgs,
    ...
  }: {
    packages.tf = pkgs.writeShellApplication {
      name = "tf";
      runtimeInputs = [self'.packages.opentofu pkgs.sops];
      text = ''
        #!/usr/bin/env bash
        set -exuo pipefail

        IGREEN='\033[1;92m'
        NC='\033[0m'
        SOPS=(sops --input-type binary --output-type binary --decrypt)

        if [[ $# -gt 0 && $1 =~ cluster ]]; then
          WORKSPACE="$1"
          shift
        else
          WORKSPACE="cluster"
        fi

        unset VAR_FILE
        if [ -s "secrets/tf/$WORKSPACE.tfvars" ]; then
          VAR_FILE="secrets/tf/$WORKSPACE.tfvars"
        fi

        echo -e "Running tofu in the ''${IGREEN}$WORKSPACE''${NC} workspace..." 1>&2
        rm --force tofu.tf.json
        nix build ".#opentofu.$WORKSPACE" --out-link tofu.tf.json 1>&2

        tofu init -reconfigure 1>&2
        tofu workspace select -or-create "$WORKSPACE" || true 1>&2
        tofu "$@" ''${VAR_FILE:+-var-file=<("''${SOPS[@]}" "$VAR_FILE")}
      '';
    };
  };
}
