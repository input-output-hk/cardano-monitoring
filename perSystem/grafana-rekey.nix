{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Re-encrypts Grafana's data keys under a new secret_key, see
    # grafana-rekey.py and docs/grafana-secret-key.md.
    # monitoring.nix installs it on every monitoring machine.
    packages.grafana-rekey =
      pkgs.writers.writePython3Bin "grafana-rekey" {
        libraries = [pkgs.python3Packages.cryptography];
      }
      (builtins.readFile ./grafana-rekey.py);

    # Checks its encryption against Grafana's own test vectors, and
    # re-encrypts a scratch database.
    checks.grafana-rekey = pkgs.runCommand "grafana-rekey" {} ''
      ${lib.getExe config.packages.grafana-rekey} self-test
      touch $out
    '';
  };
}
