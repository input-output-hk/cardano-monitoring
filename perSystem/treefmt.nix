{
  # Run `treefmt` at the root of the repository to ensure all files are
  # formatted correctly.
  perSystem.treefmt = {
    # We use alejandra to format our Nix files.
    programs.alejandra.enable = true;

    # This tells treefmt that it should start formatting starting at the
    # directory containing a flake.nix file.
    projectRootFile = "flake.nix";
  };
}
