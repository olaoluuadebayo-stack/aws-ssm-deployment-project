
#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_PAGER=""
REGION="us-east-1"
PROJECT="aws-ssm-deployment"
INSTANCE_PROFILE="aws-ssm-deployment-ec2-profile"
INSTANCE_TYPE="t3.micro"
STATE_FILE="state.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$PWD" == */aws-ssm-deployment-project ]] ||
  die "Run from ~/aws-ssm-deployment-project"

[[ -f "$STATE_FILE" ]] || die "state.env not found."
source "$STATE_FILE"

: "${VPC_ID:?VPC_ID missing}"
: "${SUBNET_ID:?SUBNET_ID missing}"
: "${SG_ID:?SG_ID missing}"
: "${ROLE_NAME:?ROLE_NAME missing}"
: "${PROFILE_NAME:?PROFILE_NAME missing}"

aws sts get-caller-identity >/dev/null ||
  die "AWS authentication failed."

# Refuse to launch a second instance for this project.
EXISTING="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text)"

[[ -z "$EXISTING" || "$EXISTING" == "None" ]] ||
  die "Project instance already exists: $EXISTING"

# Verify the instance profile contains the intended role.
PROFILE_ROLE="$(aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)"

[[ "$PROFILE_ROLE" == "$ROLE_NAME" ]] ||
  die "Instance profile does not contain the expected role."

echo "Discovering the latest Canonical Ubuntu 24.04 LTS AMI..."
AMI_ID="$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)"

[[ "$AMI_ID" == ami-* ]] || die "Could not resolve a valid Ubuntu AMI ID."

echo "Using AMI: $AMI_ID"
echo "Launching $INSTANCE_TYPE in subnet $SUBNET_ID..."

INSTANCE_ID="$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --block-device-mappings \
    '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=Production-SSM-Web-Server},{Key=Project,Value=$PROJECT}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=Production-SSM-Web-Volume},{Key=Project,Value=$PROJECT}]" \
  --count 1 \
  --query 'Instances[0].InstanceId' --output text)"

printf 'INSTANCE_ID=%q\n' "$INSTANCE_ID" >> "$STATE_FILE"

echo "Waiting for EC2 instance to become running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

INSTANCE_DETAILS="$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output text)"

PRIVATE_IP="$(awk '{print $1}' <<< "$INSTANCE_DETAILS")"
PUBLIC_IP="$(awk '{print $2}' <<< "$INSTANCE_DETAILS")"
INSTANCE_STATE="$(awk '{print $3}' <<< "$INSTANCE_DETAILS")"

printf 'PRIVATE_IP=%q\n' "$PRIVATE_IP" >> "$STATE_FILE"
printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP" >> "$STATE_FILE"

echo
echo "EC2 LAUNCH COMPLETE"
echo "Instance:   $INSTANCE_ID"
echo "State:      $INSTANCE_STATE"
echo "Private IP: $PRIVATE_IP"
echo "Public IP:  $PUBLIC_IP"
echo "AMI:        $AMI_ID"
echo "State saved to $STATE_FILE"
echo "SSM registration may take a few minutes."