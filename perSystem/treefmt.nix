{
  # Run `treefmt` at the root of the repository to ensure all files are
  # formatted correctly.
  perSystem.treefmt = {
    # We use alejandra to format our Nix files.
    programs.alejandra.enable = true;
    projectRootFile = "flake.nix";
  };
}
