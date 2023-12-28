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
is:

    just tf plan
    just tf apply

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

### Secrets

Secrets are encrypted using [SOPS](https://github.com/getsops/sops)
and [KMS](https://aws.amazon.com/kms/).

All secrets live in `./secrets/`

You should be able to edit secrets using:

    sops --kms "$KMS" ./secrets/github-token.enc

Or simply decrypt a secret with

    sops -d ./secrets/github-token.enc 
