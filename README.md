# Cardano Monitoring

The cardano-monitoring project acts as home for collecting metrics from our
Cardano clusters.

Running instances are:

- [Playground](https://playground.monitoring.aws.iohkdev.io/)
- [Mainnet](https://mainnet.monitoring.aws.iohkdev.io/)

## Getting started

While working on the next step, you can already start the devshell using:

    nix develop

This will be done automatically if you are using [direnv](https://direnv.net/).

### NixOS 26.05 upgrade

The flake pins NixOS 26.05 and a refreshed OpenTofu provider registry. Keep
`system.stateVersion = "23.05"`: it records the original installation's data
compatibility defaults and is not the OS release selector.

The upgrade includes Grafana 13, Mimir 3, Loki 3.7, and Alloy 1.16. Grafana's
previous default encryption key is now explicitly preserved because NixOS 26.05
no longer supplies it. Rotating that key requires a separate migration of
existing encrypted database settings; do not simply replace it during rollout.
See the [NixOS release notes](https://nixos.org/manual/nixos/stable/release-notes.html).
Mimir keeps its existing single-binary, classic storage architecture; its queue
limit now uses `query_scheduler.max_outstanding_requests_per_tenant` because
the old frontend setting was removed in Mimir 3.

Before rolling out, back up Grafana's database and other local service state,
then deploy and check playground before the other monitoring servers. Check
ingestion, dashboards, recording rules, and alert delivery after activation and
after rebooting into the upgraded kernel/initrd.

For OpenTofu, enter the updated development shell and run `tf init -upgrade`
to refresh any existing local provider lockfile, then review `tf plan` before
applying infrastructure changes. The AWS provider crosses a major version to
6.x; offline schema validation does not establish that a live plan is unchanged.
Provider binaries are selected for the development machine's architecture on
both supported Linux platforms.

### General

General information about this cluster is stored in the `flake/cluster.nix`
file. 

### AWS

Create an AWS user with your name and `AdministratorAccess` policy in the
cardano-monitoring organization, then store your access key in
`~/.aws/credentials` under the profile name `cardano-monitoring`:

    [cardano-monitoring]
    aws_access_key_id = XXXXXXXXXXXXXXXXXXXX
    aws_secret_access_key = XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

### SSH

If your credentials are correct, you will be able to access SSH after creating
an `./.ssh_config` using:

    just save-ssh-config

With that you can then either

    just ssh playground

or

    ssh -F .ssh_config playground

### Cloudformation

We bootstrap our infrastructure using AWS Cloudformation, it creates resources
like S3 Buckets, a DNS Zone, KMS key, and OpenTofu state storage.

The distinction of what is managed by Cloudformation and OpenTofu is not very
strict, but generally anything that is not of the mentioned resource types will
go into OpenTofu since they are harder to configure and reuse otherwise.

All configuration is in `./flake/cloudFormation/state.nix`

We use [Rain](https://github.com/aws-cloudformation/rain) to apply the
configuration. There is a wrapper that evaluates the config and deploys it:

    just cf state

### OpenTofu

We use [OpenTofu](https://opentofu.org/) to create AWS instances, roles,
profiles, policies, Route53 records, EIPs, security groups, and similar.

All configuration is in `./flake/opentofu/cluster.nix`

The wrapper to setup the state, workspace, evaluate the config, and run `tofu`
is called `tf`:

    tf plan
    tf apply

### Colmena

To deploy changes on an OS level, we use the excellent
[Colmena](https://github.com/zhaofengli/colmena).

Since our servers are running ARM CPUs, we have to compile for that
architecture. So in case you're on e.g. x86_64, you can add the following line
to your NixOS configuration to enable emulation for aarch64.

    boot.binfmt.emulatedSystems = ["aarch64-linux"];

All colmena configuration is in `./flake/colmena.nix` and the corresponding
NixOS modules are in `./flake/nixosModules/`

Then you can run `colmena` to run and apply your configuration:

    colmena build
    colmena apply

Please note that the first deploy has to be made using:

    just apply-bootstrap $node

Because it has to use the bootstrap SSH key that the AMI was provisioned with.

### Secrets

Secrets are encrypted using [SOPS](https://github.com/getsops/sops)
and [KMS](https://aws.amazon.com/kms/).

All secrets live in `./secrets/`, and `.sops.yaml` points sops at the
cluster's KMS key, so you can create or edit a secret using:

    sops ./secrets/github-token.enc

Or simply decrypt a secret with

    sops -d ./secrets/github-token.enc 

Only SOPS-encrypted files belong in `./secrets/`, so never write a decrypted
secret to a file in the repository: edit with `sops` as above, and send
`sops -d` output to the terminal or a pipe. Three safeguards back this up:

- Files in `./secrets/` that don't end in `.enc` are ignored by git, so a
  stray decrypted copy isn't picked up by `git add -A`.
- The devshell installs a pre-commit hook that refuses to commit any file
  under `./secrets/` that isn't SOPS-encrypted. It checks what is staged, so
  after encrypting a file you've already staged, `git add` it again.
- Hydra runs the same check (`checks.secrets-encrypted`) in its required
  build, so a pull request containing a plaintext secret can't be merged.

This repository is public: a plaintext secret that reaches GitHub, even on a
branch, has leaked and must be rotated.

#### Caddy

We use basic authentication for metric collection.
To generate a password for [Caddy](https://caddyserver.com/) use:

    caddy hash-password
    
The current passwords are stored in
`secrets/caddy-environment-playground.enc`
and
`secrets/caddy-environment-mainnet.enc`

### Grafana

To enable OAuth for a new monitoring instance, you have to add it to the
`Testnet` project under the `monitoring.aws.iohkdev.io` application.

After adding the new URLs for JavaScript and redirects, you need to log into
Grafana via OAuth.

Once logged in, obtain administration access to Grafana:

    just ssh yourNewServer
    nix shell nixpkgs#sqlite-interactive
    sqlite3 /var/lib/grafana/data/grafana.db
    update user set is_admin = 1 where email = 'bob@example.com';

Finally go to `Administration` -> `Users and access` -> `Users` and set
permissions on your organisation to `Admin` as well.
Once you refresh, you can start creating a service account as per the
instructions in `grafana.tfvars`
