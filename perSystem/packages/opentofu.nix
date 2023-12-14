{
  inputs,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: {
    packages.opentofu = let
      mkTerraformProvider = {
        owner,
        repo,
        version,
        src,
        registry ? "registry.opentofu.org",
      }: let
        inherit (pkgs.go) GOARCH GOOS;
        provider-source-address = "${registry}/${owner}/${repo}";
      in
        pkgs.stdenv.mkDerivation {
          pname = "terraform-provider-${repo}";
          inherit version src;

          unpackPhase = "unzip -o $src";

          nativeBuildInputs = [pkgs.unzip];

          buildPhase = ":";

          # The upstream terraform wrapper assumes the provider filename here.
          installPhase = ''
            dir=$out/libexec/terraform-providers/${provider-source-address}/${version}/${GOOS}_${GOARCH}
            mkdir -p "$dir"
            mv terraform-* "$dir/"
          '';

          passthru = {
            inherit provider-source-address;
          };
        };

      readJSON = f: builtins.fromJSON (lib.readFile f);

      # fetch the latest version
      providerFor = owner: repo: let
        json = readJSON (inputs.opentofu-registry + "/providers/${lib.substring 0 1 owner}/${owner}/${repo}.json");
        latest = lib.head json.versions;
        matching = lib.filter (e: e.os == "linux" && e.arch == "amd64") latest.targets;
        target = lib.head matching;
      in
        mkTerraformProvider {
          inherit (latest) version;
          inherit owner repo;
          src = pkgs.fetchurl {
            url = target.download_url;
            sha256 = target.shasum;
          };
        };
    in
      pkgs.opentofu.withPlugins (_: [
        (providerFor "fgouteroux" "loki")
        (providerFor "fgouteroux" "mimir")
        (providerFor "grafana" "grafana")
        (providerFor "opentofu" "aws")
        (providerFor "opentofu" "local")
        (providerFor "opentofu" "external")
        (providerFor "opentofu" "null")
        (providerFor "opentofu" "tls")
        (providerFor "loafoe" "ssh")
      ]);
  };
}
