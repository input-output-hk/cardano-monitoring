set shell := ["nu", "-c"]
set positional-arguments
AWS_PROFILE := 'cardano-monitoring'
AWS_REGION := 'eu-central-1'

checkSshConfig := '''
  if not ('.ssh_config' | path exists) {
    just save-ssh-config
  }
'''

default:
  @just --list

lint:
  deadnix -f
  statix check

show-flake *ARGS:
  nix flake show {{ARGS}}

apply *ARGS:
  colmena apply --keep-result --verbose --on {{ARGS}}

apply-all *ARGS:
  colmena apply --keep-result --verbose {{ARGS}}

build-machine MACHINE *ARGS:
  nix build -L .#nixosConfigurations.{{MACHINE}}.config.system.build.toplevel {{ARGS}}

build-machines *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  for node in $nodes {just build-machine $node {{ARGS}}}

scp *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  scp -o LogLevel=ERROR -F .ssh_config {{ARGS}}

ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ssh -o LogLevel=ERROR -F .ssh_config {{HOSTNAME}} {{ARGS}}

ssh-bootstrap HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  if not ('.ssh_key' | path exists) {
    just save-bootstrap-ssh-key
  }
  ssh -o LogLevel=ERROR -F .ssh_config -i .ssh_key {{HOSTNAME}} {{ARGS}}

ssh-for-all *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  $nodes | par-each {|node| just ssh -q $node {{ARGS}}}

ssh-for-each HOSTNAMES *ARGS:
  colmena exec --verbose --parallel 0 --on {{HOSTNAMES}} {{ARGS}}

ssh-list-ips HOSTNAME_REGEX_PATTERN:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ( scj dump /dev/stdout -c .ssh_config
  | from json
  | default "" Host
  | default "" HostName
  | where Host =~ {{HOSTNAME_REGEX_PATTERN}} and HostName != ""
  | get HostName
  | str join " " )

ssh-list-names HOSTNAME_REGEX_PATTERN:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ( scj dump /dev/stdout -c .ssh_config
  | from json
  | default "" Host
  | default "" HostName
  | where Host =~ {{HOSTNAME_REGEX_PATTERN}} and HostName != ""
  | get Host
  | str join " " )

cf STACKNAME:
  #!/usr/bin/env nu
  nix eval --json '.#cloudFormation.{{STACKNAME}}' | from json | save --force '{{STACKNAME}}.json'
  rain deploy --debug --termination-protection --yes {{STACKNAME}}.json

tf *ARGS:
  #!/usr/bin/env bash
  set -exuo pipefail
  IGREEN='\033[1;92m'
  IRED='\033[1;91m'
  NC='\033[0m'
  SOPS=(sops --input-type binary --output-type binary --decrypt)

  read -r -a ARGS <<< "{{ARGS}}"
  if [[ ${ARGS[0]} =~ cluster ]]; then
    WORKSPACE="${ARGS[0]}"
    ARGS=("${ARGS[@]:1}")
  else
    WORKSPACE="cluster"
  fi

  unset VAR_FILE
  if [ -s "secrets/tf/$WORKSPACE.tfvars" ]; then
    VAR_FILE="secrets/tf/$WORKSPACE.tfvars"
  fi

  echo -e "Running tofu in the ${IGREEN}$WORKSPACE${NC} workspace..."
  rm --force tofu.tf.json
  nix build ".#opentofu.$WORKSPACE" --out-link tofu.tf.json

  tofu init -reconfigure
  tofu workspace select -or-create "$WORKSPACE" || true
  tofu ${ARGS[@]} ${VAR_FILE:+-var-file=<("${SOPS[@]}" "$VAR_FILE")}

tf-fast *ARGS:
  #!/usr/bin/env bash
  set -exuo pipefail
  IGREEN='\033[1;92m'
  IRED='\033[1;91m'
  NC='\033[0m'
  SOPS=(sops --input-type binary --output-type binary --decrypt)

  read -r -a ARGS <<< "{{ARGS}}"
  if [[ ${ARGS[0]} =~ cluster ]]; then
    WORKSPACE="${ARGS[0]}"
    ARGS=("${ARGS[@]:1}")
  else
    WORKSPACE="cluster"
  fi

  unset VAR_FILE
  if [ -s "secrets/tf/$WORKSPACE.tfvars" ]; then
    VAR_FILE="secrets/tf/$WORKSPACE.tfvars"
  fi

  echo -e "Running tofu in the ${IGREEN}$WORKSPACE${NC} workspace..."
  rm --force tofu.tf.json
  nix build ".#opentofu.$WORKSPACE" --out-link tofu.tf.json

  tofu ${ARGS[@]} ${VAR_FILE:+-var-file=<("${SOPS[@]}" "$VAR_FILE")}

update-aws-ec2-spec profile=AWS_PROFILE region=AWS_REGION:
  #!/usr/bin/env nu
  # To describe instance types, any valid aws profile can be provided
  # Default region for specs will be eu-central-1 which provides ~600 machine defns
  let spec = (
    do -c { aws ec2 --profile {{profile}} --region {{region}} describe-instance-types }
    | from json
    | get InstanceTypes
    | select InstanceType MemoryInfo VCpuInfo
    | reject VCpuInfo.ValidCores? VCpuInfo.ValidThreadsPerCore?
    | sort-by InstanceType
  )
  mkdir flakeModules/aws/
  {InstanceTypes: $spec} | save --force flakeModules/aws/ec2-spec.json

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

save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from tofu..."
  tofu workspace select -or-create cluster
  tofu init -reconfigure
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

save-ssh-config:
  #!/usr/bin/env nu
  print "Retrieving ssh config from tofu..."
  tofu workspace select -or-create cluster
  tofu init -reconfigure
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == local_file and name == ssh_config)
  $key.values.content | save --force .ssh_config
  chmod 0600 .ssh_config
