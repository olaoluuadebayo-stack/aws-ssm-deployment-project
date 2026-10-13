
#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_PAGER=""
REGION="us-east-1"
PROJECT="aws-ssm-deployment"
ROLE_NAME="aws-ssm-deployment-ec2-role"
PROFILE_NAME="aws-ssm-deployment-ec2-profile"
POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
STATE_FILE="state.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$PWD" == */aws-ssm-deployment-project ]] ||
  die "Run from ~/aws-ssm-deployment-project"

[[ -f "$STATE_FILE" ]] || die "state.env not found."

# Load only the resource IDs recorded by our setup script.
source "$STATE_FILE"

: "${VPC_ID:?VPC_ID missing}"
: "${SUBNET_ID:?SUBNET_ID missing}"
: "${SG_ID:?SG_ID missing}"

aws sts get-caller-identity >/dev/null ||
  die "AWS authentication failed."

# Refuse to silently adopt or overwrite an existing role.
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  die "Role $ROLE_NAME already exists. Inspect it before proceeding."
fi

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  die "Instance profile $PROFILE_NAME already exists. Inspect it before proceeding."
fi

umask 077
TRUST_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE"' EXIT

cat > "$TRUST_FILE" <<'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST

echo "Creating EC2 role..."
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://$TRUST_FILE" \
  --description "Project 2 EC2 role for AWS Systems Manager" \
  --tags Key=Project,Value="$PROJECT" \
  >/dev/null

# Save the role name immediately after creation.
printf 'ROLE_NAME=%q\n' "$ROLE_NAME" >> "$STATE_FILE"

echo "Attaching Systems Manager permissions..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

echo "Creating instance profile..."
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT" \
  >/dev/null

printf 'PROFILE_NAME=%q\n' "$PROFILE_NAME" >> "$STATE_FILE"

echo "Adding role to instance profile..."
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

echo
echo "IAM ROLE STAGE COMPLETE"
echo "Role: $ROLE_NAME"
echo "Instance profile: $PROFILE_NAME"
echo "Managed policy: AmazonSSMManagedInstanceCore"
echo "State saved to $STATE_FILE"