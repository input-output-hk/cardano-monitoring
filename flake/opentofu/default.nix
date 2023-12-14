{lib, ...}: {
  options = {
    flake.opentofu = lib.mkOption {
      type = lib.types.attrs;
    };
  };
}
