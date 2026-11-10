# Grafana secret key switch-over

These steps move a machine's Grafana off the public default `secret_key`
and onto the machine's own key (see "Grafana secret key" in the
[README](../README.md#grafana-secret-key)). Grafana can't move its
database to another key, so `grafana-rekey`, which is installed on every
machine, re-encrypts it for the new key first. Each machine needs this
once. When every machine has `monitoring.grafanaSecretKeyRotated` set,
this page can go, along with the option.

To switch a machine over, follow the steps below. From stopping Grafana in
step 5 until step 7, nothing else may start it: a deploy of the machine
without `monitoring.grafanaSecretKeyRotated` set, or a reboot, would start
Grafana with the old key on the re-keyed database. Grafana doesn't notice a
wrong key. It reads garbage for its secrets, and nothing it encrypts then
can be read once it has the new key. So make sure nobody else deploys the
machine in between.

1. Deploy the machine with its key file in place, but don't set
   `monitoring.grafanaSecretKeyRotated` for it yet. The key file has to be
   tracked by git, or Nix won't see it:

       colmena apply --on <machine>

   That installs the key at `/run/secrets/grafana-secret-key`. Because the
   key file is new, the deploy restarts Grafana once, still with the old
   key, so nobody is signed out. If an earlier deploy already installed the
   key file, skip to step 2.

2. On the machine as root, check that the key file is there and Grafana is
   running again:

       ls -l /run/secrets/grafana-secret-key
       systemctl is-active grafana

   The file should be owned by `grafana` with mode `-r--------`, and
   `systemctl` should print `active`.

3. On the machine as root, check the old key against the database, changing
   nothing:

       sudo -u grafana grafana-rekey check --db /var/lib/grafana/data/grafana.db \
         --from-default --to /run/secrets/grafana-secret-key

   If it refuses with "Move them onto data keys first", some secrets are
   still encrypted directly with the key. Carry on: step 5 moves them, and
   `rekey` repeats this check before it writes anything. If it asks for
   `--allow-unverified`, no secret in the database is long enough to confirm
   the key, so a wrong key would pass unnoticed. Add the flag here and to
   `rekey` only if the machine has always run with the public default key,
   and then don't count the `check`s in step 8 as proof.

4. Set `monitoring.grafanaSecretKeyRotated = true` for the machine, and copy
   its new system to it without activating it:

       colmena apply push --on <machine>

5. On the machine as root, stop Grafana and move any secret still encrypted
   directly with the key onto data keys:

       # Grafana's CLI needs the binary and config of the running service.
       read -r grafana _ _ home _ config \
         < <(tr '\0' ' ' < /proc/"$(systemctl show -P MainPID grafana)"/cmdline)
       [ -x "$grafana" ] && systemctl stop grafana &&
         sudo -u grafana "$grafana" cli --homepath "$home" --config "$config" \
           admin secrets-migration re-encrypt

   Read its output: every column should be "re-encrypted successfully". The
   exit status doesn't tell you, because Grafana's CLI exits 0 even when it
   logs "re-encrypted with errors" for a column (just above, it names the
   table and id of each row it couldn't re-encrypt).

   If it stopped at once because Grafana wasn't running (it prints
   `/proc/0/cmdline: No such file or directory`), start Grafana, which still
   has the old key, and begin step 5 again. If a column was re-encrypted
   with errors, stop: see "If step 5 or 6 fails" below. Once step 6 has run,
   don't run the `grafana cli` line again: its config has the old key, so
   it would overwrite the secrets with garbage.

6. On the machine as root, back up the database and re-encrypt its data
   keys for the new key:

       sudo -u grafana grafana-rekey rekey --db /var/lib/grafana/data/grafana.db \
         --from-default --to /run/secrets/grafana-secret-key

   It prints a `backup:` line and `re-encrypted <n> data keys with the new
   key`. If it refuses or fails instead, stop: see "If step 5 or 6 fails"
   below.

7. On the machine as root, check that the database now decrypts with the
   new key:

       sudo -u grafana grafana-rekey check --db /var/lib/grafana/data/grafana.db \
         --from /run/secrets/grafana-secret-key

   If it ends with `nothing written`, run `colmena apply --on <machine>`
   straight away. That starts Grafana with the new key. If the check fails
   instead, don't apply: the database isn't re-keyed. Do step 6 if you
   skipped it, and otherwise see "If step 5 or 6 fails" below. If the apply
   fails, run it again, and don't start Grafana by hand until it has
   succeeded: until the new system is active, Grafana would start with the
   old key. Everyone has to sign in again, because Grafana's sessions are
   tied to the key.

8. On the machine as root, confirm it:

       # Both of Grafana's secret_key settings should name the key file.
       pid=$(systemctl show -P MainPID grafana)
       config=$(tr '\0' '\n' < /proc/"$pid"/cmdline | sed -n 6p)
       awk '/^\[/ {section = $0} /^secret_key/ {print section, $0}' "$config"

       # Every secret should decrypt with the new key...
       sudo -u grafana grafana-rekey check --db /var/lib/grafana/data/grafana.db \
         --from /run/secrets/grafana-secret-key

       # ...and no longer with the public one, so this should fail.
       sudo -u grafana grafana-rekey check --db /var/lib/grafana/data/grafana.db \
         --from-default

       # Grafana shouldn't log decryption errors.
       run=$(systemctl show -P InvocationID grafana)
       journalctl -o cat _SYSTEMD_INVOCATION_ID="$run" |
         grep -i -E 'level=(error|warn).*(decrypt|cipher|secret|data.?key)'

   The first `check` should report about as many secrets as step 3 did.
   The two `check`s are the proof: Grafana reads the same key file, and a
   wrong key gives it garbage rather than errors, so the journal is only a
   sign. If the config still shows `SW2YcwTIb9zpOOhoPsMm`, Grafana is using
   the old key on the re-keyed database: stop it at once, make sure the
   option is set, and apply again. In the UI, test the data sources that
   have a password or token, but not a PagerDuty contact point, which would
   page.

9. Once the machine has run fine for a while, delete the backup `rekey`
   made, which ends the chance to undo the rotation. It's a full copy of
   `grafana.db` under the old, public key, so a volume snapshot or an image
   of the data directory would still expose every secret. Any other copy of
   `grafana.db` there, such as one made by hand before an upgrade, exposes
   them too. List the copies and remove them, but not `grafana.db` itself or
   SQLite's `grafana.db-journal`, `-wal` and `-shm` files:

       ls -l /var/lib/grafana/data/grafana.db?*

## If step 5 or 6 fails

Don't run step 7. If `grafana-rekey rekey` had already printed a backup
path, copy that backup over `grafana.db`. Then start Grafana again, still
on the old key, and unset `monitoring.grafanaSecretKeyRotated` for the
machine.

## Undoing a switch-over

To undo it before step 9, unset `monitoring.grafanaSecretKeyRotated` and
push as in step 4. Then stop Grafana, copy the newest
`grafana.db.pre-rekey-*` (the one `rekey` printed after `backup:`) back over
`grafana.db` (losing anything changed in Grafana since), and run
`colmena apply --on <machine>` straight away. As between steps 5 and 7,
nothing else may start Grafana until that apply: the machine's active system
and its boot default still carry the new key, so a reboot, or a deploy that
still sets `monitoring.grafanaSecretKeyRotated`, would start it with the new
key on the restored database.
