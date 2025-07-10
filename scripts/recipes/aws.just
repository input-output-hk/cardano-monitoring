# AWS specific recipes related to non-Tofu infrastructure.
# Doing so will make diffing and patching the main repo Justfile easier.

# Describe an aws ec2 machine
aws-ec2-describe NAME REGION *ARGS:
  #!/usr/bin/env bash
  set -e
  ID=$(just aws-ec2-id {{NAME}} {{REGION}})
  aws --region {{REGION}} ec2 describe-instances --instance-ids "$ID" {{ARGS}}

# Get an aws ec2 machine id
aws-ec2-id NAME REGION:
  #!/usr/bin/env bash
  set -e
  ID=$(aws --region {{REGION}} ec2 describe-instances --filters "Name=tag:Name,Values={{NAME}}" --output text --query "Reservations[*].Instances[*].InstanceId")
  if [ -z "${ID:-}" ]; then
    echo >&2 "ERROR: Machine {{NAME}} not found in region {{REGION}}"
    exit 1
  fi
  echo "$ID"

# Start an aws ec2 machine
aws-ec2-start NAME REGION *ARGS:
  #!/usr/bin/env bash
  set -e
  ID=$(just aws-ec2-id {{NAME}} {{REGION}})
  aws --region {{REGION}} ec2 start-instances --instance-ids "$ID" {{ARGS}}

# Get an aws ec2 machine status
aws-ec2-status NAME REGION *ARGS:
  #!/usr/bin/env bash
  set -e
  ID=$(just aws-ec2-id {{NAME}} {{REGION}})
  aws --region {{REGION}} ec2 describe-instance-status --include-all-instances --instance-ids "$ID" {{ARGS}}

# Stop an aws ec2 machine
aws-ec2-stop NAME REGION *ARGS:
  #!/usr/bin/env bash
  set -e
  ID=$(just aws-ec2-id {{NAME}} {{REGION}})
  aws --region {{REGION}} ec2 stop-instances --instance-ids "$ID" {{ARGS}}

# Describe ssm active sessions
aws-ssm-sessions *ARGS:
  #!/usr/bin/env bash
  set -e
  aws ssm describe-sessions --state Active {{ARGS}}

# Export short term aws sso credentials
aws-sso-export FILE="aws-sso.sh" AWS_PROFILE=null *ARGS:
  #!/usr/bin/env bash
  set -e
  if [ -n "{{AWS_PROFILE}}" ]; then
    PROFILE="{{AWS_PROFILE}}"
    echo "Exporting short term AWS SSO credentials for profile \"$PROFILE\" to file: {{FILE}}..."
  elif [ -n "$AWS_PROFILE" ]; then
    PROFILE="$AWS_PROFILE"
    echo "Exporting short term AWS SSO credentials for profile \"$PROFILE\" from env var AWS_PROFILE to file {{FILE}}..."
  else
    echo "ERROR: Either a recipe AWS_PROFILE arg must be given or the env var AWS_PROFILE must be set."
  fi

  if ! aws sts get-caller-identity --profile "$AWS_PROFILE" | grep "arn:aws:sts" &> /dev/null; then
    echo
    nu -c 'print $"(ansi "bg_light_red")Please run:(ansi reset) `just aws-sso-login` first to obtain sso credentials"'
    exit 1
  fi

  echo
  aws configure export-credentials --format env {{ARGS}} > {{FILE}}

# Login to aws sso
aws-sso-login AWS_PROFILE=null *ARGS:
  #!/usr/bin/env bash
  set -e
  if [ -n "{{AWS_PROFILE}}" ]; then
    PROFILE="{{AWS_PROFILE}}"
    echo "Logging into AWS SSO using profile \"$PROFILE\" from cli..."
  elif [ -n "$AWS_PROFILE" ]; then
    PROFILE="$AWS_PROFILE"
    echo "Logging into AWS SSO using profile \"$PROFILE\" from env var AWS_PROFILE..."
  else
    echo "ERROR: Either a recipe AWS_PROFILE arg must be given or the env var AWS_PROFILE must be set."
  fi

  echo
  aws sso login --profile "$PROFILE" {{ARGS}}
