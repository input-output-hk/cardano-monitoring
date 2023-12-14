{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations = (inputs.colmena.lib.makeHive self.colmena).nodes;
}
