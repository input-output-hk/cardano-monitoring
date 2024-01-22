{inputs, ...}: {
  flake.lib = inputs.nixpkgs.lib.extend (_self: lib: {
    recursiveImports = let
      # Recursively constructs an attrset of a given folder, recursing on
      # directories, value of attrs is the filetype
      getDir = dir:
        lib.mapAttrs
        (
          file: type:
            if type == "directory"
            then getDir "${dir}/${file}"
            else type
        )
        (builtins.readDir dir);

      # Collects all files of a directory as a list of strings of paths
      files = path:
        if lib.pathType path == "directory"
        then
          lib.collect lib.isString (lib.mapAttrsRecursive
            (path: _type: lib.concatStringsSep "/" path)
            (getDir path))
        else [path];

      # Select files ending with .nix
      nixFiles = path: lib.filter (lib.hasSuffix ".nix") (files path);

      # ensure all files are absolute paths
      makeAbsolute = path: file:
        if lib.hasPrefix "/nix/store" file
        then file
        else path + "/${file}";

      # Select files that with .nix suffix and also make the strings
      # absolute path based
      validFiles = path: map (makeAbsolute path) (nixFiles path);
    in
      lib.concatMap validFiles;
  });
}
