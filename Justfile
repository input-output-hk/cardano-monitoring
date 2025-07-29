import? 'scripts/recipes/aws.just'

set shell := ["nu", "-c"]
set positional-arguments

alias terraform := tofu
alias tf := tofu

# Defaults
null := ""
AWS_PROFILE := 'cardano-monitoring'
AWS_REGION := 'eu-central-1'
WORKSPACE := 'cluster'

checkSshConfig := '''
  if not ('.ssh_config' | path exists) {
    just save-ssh-config
  }
  if not ('.ssh_key' | path exists) {
    just save-bootstrap-ssh-key
  }
'''

# List all just recipes available
default:
  @just --list

# Deploy select machines
apply *ARGS:
  colmena apply --keep-result --verbose --on {{ARGS}}

# Deploy all machines
apply-all *ARGS:
  colmena apply --keep-result --verbose {{ARGS}}

# Deploy select machines with the bootstrap key
apply-bootstrap HOSTNAME:
  #!/usr/bin/env nu
  {{checkSshConfig}}

  ( open .ssh_config
  | str replace
    "Host {{HOSTNAME}}"
    "Host {{HOSTNAME}}\n  IdentityFile .ssh_key"
  ) | save -f .ssh_config_bootstrap

  with-env {
    SSH_CONFIG_FILE: .ssh_config_bootstrap
  } {
    print $"SSH_CONFIG_FILE: ($env.SSH_CONFIG_FILE)"
    colmena apply --keep-result --verbose --on {{HOSTNAME}}
  }

# Generate repo docs
book:
  tofu fmt docs/grafana.tf
  mdbook build docs/

# Build a nixos configuration
build-machine MACHINE *ARGS:
  nix build -L .#nixosConfigurations.{{MACHINE}}.config.system.build.toplevel {{ARGS}}

# Build all nixosConfigurations
build-machines *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  for node in $nodes {just build-machine $node {{ARGS}}}

# Standard lint check
lint:
  deadnix -f
  statix check -i .direnv

# List machines in the cluster
list-machines:
  #!/usr/bin/env nu

  def safe-run [block msg] {
    let res = (do -i $block | complete)
    if $res.exit_code != 0 {
      print $msg
      print "The output was:"
      print
      print $res
      exit 1
    }
    $res.stdout
  }

  def default-row [machine] {
    {
      Name: $machine,
      Nix: $"(ansi green)OK",
      pubIpv4: $"(ansi red)--",
      # pubIpv6: $"(ansi red)--",
      Id: $"(ansi red)--",
      Type: $"(ansi red)--"
      Region: $"(ansi red)--"
    }
  }

  def main [] {
    {{checkSshConfig}}

    let nixosJson = (safe-run { ^nix eval --json ".#nixosConfigurations" --apply "builtins.attrNames" } "Nix eval failed.")
    let sshJson = (safe-run { ^scj dump /dev/stdout -c .ssh_config } "scj failed.")

    let baseTable = ($nixosJson | from json | each { |it| default-row $it })
    let sshTable = ($sshJson | from json | where {|e| $e | get -i HostName | is-not-empty } | reject -i ProxyCommand)

    let mergeTable = (
      $sshTable | reduce --fold $baseTable { |it, acc|
        let host = $it.Host
        let hostData = $it.HostName
        let machine = ($host | str replace -r '\.ipv(4|6)$' '')

        let update = if ($host | str ends-with ".ipv4") {
          { pubIpv4: $hostData, Region: $it.Tag }
        # } else if ($host | str ends-with ".ipv6") {
        #   { pubIpv6: $hostData }
        } else {
          { Id: $hostData, Type: $it.Tag }
        }

        if ($acc | any {|row| $row.Name == $machine }) {
          $acc | each {|row|
            if $row.Name == $machine {
              $row | merge $update
            } else {
              $row
            }
          }
        } else {
          $acc ++ [ (default-row $machine | merge $update) ]
        }
      }
    )

    $mergeTable
      | sort-by Name
      | enumerate
      | each { |r| { index: ($r.index + 1) } | merge $r.item }
  }

# Alias for list-machines recipe
ls:
  @just list-machines

# Bootstrap a mimir url
mimir-bootstrap URL:
  # URL example: https://playground.monitoring.aws.iohkdev.io/mimir
  if not ('fallback.yml' | path exists) { print "Please create a fallback.yml file"; exit }
  mimirtool alertmanager load --log.level=debug --address {{URL}} --id anonymous fallback.yml

# Scp using repo ssh config
scp *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  scp -o LogLevel=ERROR -F .ssh_config {{ARGS}}

# Show nix flake details
show-flake *ARGS:
  nix flake show --allow-import-from-derivation {{ARGS}}

# Ssh using repo ssh config
ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ssh -o LogLevel=ERROR -F .ssh_config {{HOSTNAME}} {{ARGS}}

# Ssh using cluster bootstrap key
ssh-bootstrap HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ssh -o LogLevel=ERROR -F .ssh_config -i .ssh_key {{HOSTNAME}} {{ARGS}}

# Ssh to all
ssh-for-all *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  $nodes | par-each {|node|
    let result = (do -i { ^just ssh -q $node {{ARGS}} } | complete)
    {
      index: $node,
      result: $result
    }
  }

# Ssh for select
ssh-for-each HOSTNAMES *ARGS:
  colmena exec --verbose --parallel 0 --on {{HOSTNAMES}} {{ARGS}}

# List machine id, ipv4, name, region or type based on regex pattern
ssh-list TYPE PATTERN:
  #!/usr/bin/env nu
  const type = "{{TYPE}}"

  let sshCfg = (
    scj dump /dev/stdout -c .ssh_config
      | from json
      | default "" Host
      | default "" HostName
  )

  if ($type == "id") {
    $sshCfg
      | where not ($it.Host =~ ".ipv(4|6)$")
      | where Host =~ "{{PATTERN}}"
      | get HostName
      | str join " "
  } else if ($type == "ipv4") {
    $sshCfg
      | where ($it.Host =~ ".ipv4$")
      | where Host =~ "{{PATTERN}}"
      | get HostName
      | str join " "
  # } else if ($type == "ipv6") {
  #   $sshCfg
  #     | where ($it.Host =~ ".ipv6$")
  #     | where Host =~ "{{PATTERN}}"
  #     | get HostName
  #     | str join " "
  } else if ($type == "name") {
    $sshCfg
      | where not ($it.Host =~ ".ipv(4|6)$")
      | where Host =~ "{{PATTERN}}"
      | get Host
      | str join " "
  } else if ($type == "region") {
    $sshCfg
      | where ($it.Host =~ ".ipv4$")
      | where Host =~ "{{PATTERN}}"
      | get Tag
      | str join " "
  } else if ($type == "type") {
    $sshCfg
      | where not ($it.Host =~ ".ipv(4|6)$")
      | where Host =~ "{{PATTERN}}"
      | get Tag
      | str join " "
  } else {
    # print "The TYPE must be one of: id, ipv4, ipv6, name, region or type"
    print "The TYPE must be one of: id, ipv4, name, region or type"
  }

# Run tofu cmds
tofu *ARGS:
  #!/usr/bin/env bash
  set -euo pipefail
  IGREEN='\033[1;92m'
  IRED='\033[1;91m'
  NC='\033[0m'
  SOPS=("sops" "--input-type" "binary" "--output-type" "binary" "--decrypt")

  # There is currently only a "cluster" workspace which is in use
  WORKSPACE="cluster"

  echo -e "Running tofu in the ${IGREEN}$WORKSPACE${NC} workspace..."
  rm --force tofu.tf.json
  nix build ".#opentofu.$WORKSPACE" --out-link tofu.tf.json

  tofu init -reconfigure
  tofu workspace select -or-create "$WORKSPACE"
  tofu {{ARGS}}

# Save the cluster bootstrap ssh key
save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from tofu..."
  nix build ".#opentofu.{{WORKSPACE}}" --out-link tofu.tf.json
  tofu workspace select -or-create cluster
  tofu init -reconfigure
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

# Show DNS nameservers
show-nameservers:
  #!/usr/bin/env nu
  let domain = (nix eval --raw '.#cluster.infra.aws.domain')
  let zones = (aws route53 list-hosted-zones-by-name | from json).HostedZones
  let id = ($zones | where Name == $"($domain).").Id.0
  let sets = (aws route53 list-resource-record-sets --hosted-zone-id $id | from json).ResourceRecordSets
  let ns = ($sets | where Type == "NS").ResourceRecords.0.Value
  print "Nameservers for the following hosted zone need to be added to the NS record of the delegating authority"
  print $"Nameservers for domain: ($domain) \(hosted zone id: ($id)) are:"
  print ($ns | to text)

# Save ssh config
save-ssh-config:
  #!/usr/bin/env nu
  print "Retrieving ssh config from tofu..."
  nix build ".#opentofu.{{WORKSPACE}}" --out-link tofu.tf.json
  tofu workspace select -or-create cluster
  # tofu init -reconfigure
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == local_file and name == ssh_config)
  $key.values.content | save --force $env.SSH_CONFIG_FILE
  chmod 0600 $env.SSH_CONFIG_FILE
  print $"Saved to ($env.SSH_CONFIG_FILE)"
