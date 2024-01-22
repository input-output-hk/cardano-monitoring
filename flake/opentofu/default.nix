{lib, ...}: {
  # This option allows us to build our OpenTofu configurations.
  # For example:
  # nix build --print-out-paths '.#opentofu.cluster'
  # This is used by our Justfile via `just tf`
  options.flake.opentofu = lib.mkOption {
    type = lib.types.attrs;
  };
}
