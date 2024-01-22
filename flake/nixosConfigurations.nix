{
  inputs,
  self,
  ...
}: {
  # We evaluate the cluster and provide each node as a separate output. This way
  # we don't have to duplicate our configuration for Colmena and still can use
  # nix build .#nixosConfigurations.playground.config.system.build.toplevel
  # to ensure that the system builds correctly or to debug things, it's also
  # compatible with `nixos-rebuild` that way.
  flake.nixosConfigurations = (inputs.colmena.lib.makeHive self.colmena).nodes;
}
