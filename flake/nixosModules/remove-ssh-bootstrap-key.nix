{
  flake.nixosModules.remove-ssh-bootstrap-key = {
    lib,
    pkgs,
    config,
    ...
  }: {
    systemd = {
      # When initially deploying a system, we have to set an SSH key to login.
      # That key is called the bootstrap key, and is generated automatically
      # by OpenTofu. The key then gets passed to the NixOS AMI user data,
      # which sets it in the authorized_keys file of the root user.
      #
      # We assume that within one week, the inital deployment and testing
      # has completed, and access using this key is not required anymore.
      #
      # We prefer having only keys specified in the auth-keys-hub config to
      # be allowed.
      timers.remove-ssh-bootstrap-key = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "daily";
          Unit = "remove-ssh-bootstrap-key.service";
        };
      };

      services.remove-ssh-bootstrap-key = {
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];

        serviceConfig = {
          Type = "oneshot";

          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "remove-ssh-bootstrap-key";
            runtimeInputs = with pkgs; [fd gnugrep gnused];
            text = ''
              set -euo pipefail

              if [ -f /root/.ssh/.bootstrap-key-removed ]; then
                echo "Nothing to do"
              elif ! grep -q 'AuthorizedKeysCommand /etc/ssh/auth-keys-hub --user %u' /etc/ssh/sshd_config; then
                echo "SSH daemon authorized keys command does not appear to have auth-keys-hub installed"
              elif ! grep -q 'AuthorizedKeysCommandUser ${config.programs.auth-keys-hub.user}' /etc/ssh/sshd_config; then
                echo "SSH daemon authorized keys command user does not appear to be using the ${config.programs.auth-keys-hub.user} user"
              elif ! grep -q -E '^ssh-' /etc/ssh/authorized_keys.d/root &> /dev/null; then
                echo "You must declare at least 1 authorized key via users.users.root.openssh.authorizedKeys attribute before the bootstrap key will be removed"
              elif fd --quiet --changed-within 7d authorized_keys /root/.ssh; then
                echo "The root authorized_keys file has been changed within the past week. Waiting a little longer before removing the bootstrap key"
              else
                # Remove the bootstrap key and set a marker
                echo "Removing the bootstrap key from /root/.ssh/authorized_keys"
                sed -i '/bootstrap/d' /root/.ssh/authorized_keys
                touch /root/.ssh/.bootstrap-key-removed
              fi
            '';
          });
        };
      };
    };
  };
}
