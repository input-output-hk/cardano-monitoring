{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Fails unless every file under secrets/ is SOPS-encrypted.
    # Without arguments it checks what is staged, which is how the devShell's
    # git pre-commit hook runs it. Given directories, it checks the files in
    # them instead.
    packages.check-secrets = pkgs.writeShellApplication {
      name = "check-secrets";
      runtimeInputs = with pkgs; [findutils gitMinimal sops];
      text = ''
        # Reads the file content from stdin. Secrets are stored in sops binary
        # format whatever the file is called, so don't let sops pick a format
        # from the extension. Binary also accepts sops JSON files; sops YAML,
        # dotenv and INI files are refused.
        encrypted() {
          [ "$(sops filestatus --input-type binary /dev/stdin 2>/dev/null)" = '{"encrypted":true}' ]
        }

        unencrypted=()
        if [ $# -eq 0 ]; then
          # Check the index, not the working tree: a file staged as plaintext
          # and encrypted afterwards is still committed as plaintext.
          while IFS= read -r -d "" path; do
            git cat-file blob ":$path" | encrypted || unencrypted+=("$path")
          done < <(git diff --cached --name-only --diff-filter=d -z -- :/secrets/)
        else
          while IFS= read -r -d "" path; do
            encrypted < "$path" || unencrypted+=("$path")
          done < <(find "$@" ! -type d -print0)
        fi

        if [ ''${#unencrypted[@]} -gt 0 ]; then
          echo "Not SOPS-encrypted:" >&2
          printf '  %s\n' "''${unencrypted[@]}" >&2
          if [ $# -eq 0 ]; then
            echo "Commit refused. Encrypt with: sops -e -i <file>, then git add it again." >&2
            echo "Or leave it out of the commit with: git restore --staged <file>" >&2
          else
            echo "This repository is public: if these were pushed, rotate them." >&2
          fi
          exit 1
        fi
      '';
    };

    checks.secrets-encrypted = pkgs.runCommand "secrets-encrypted" {} ''
      ${lib.getExe config.packages.check-secrets} ${../secrets}
      touch $out
    '';
  };
}
