
#!/usr/bin/env bash
set -Eeuo pipefail

# Project 2: EC2 + SSM Deployment Automation
# Stage 1: Network foundation only.
# Region and resource names are fixed in PROJECT_PLAN.md.

export AWS_PAGER=""
REGION="us-east-1"
PROJECT="aws-ssm-deployment"
VPC_CIDR="10.40.0.0/16"
SUBNET_CIDR="10.40.1.0/24"

STATE_FILE="state.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"
}

need_command aws

[[ "$PWD" == */aws-ssm-deployment-project ]] ||
  die "Run this script from ~/aws-ssm-deployment-project"

[[ ! -e "$STATE_FILE" ]] ||
  die "$STATE_FILE already exists. Inspect it before proceeding."

aws sts get-caller-identity --output json >/dev/null ||
  die "AWS authentication failed. Re-authenticate and retry."

CURRENT_REGION="$(aws configure get region || true)"
if [[ -n "$CURRENT_REGION" && "$CURRENT_REGION" != "$REGION" ]]; then
  echo "Configured region is $CURRENT_REGION; this project explicitly uses $REGION."
fi

# Refuse to proceed if the dedicated project VPC already exists.
EXISTING_VPC="$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[0].VpcId' --output text)"

[[ "$EXISTING_VPC" == "None" || -z "$EXISTING_VPC" ]] ||
  die "A project VPC already exists: $EXISTING_VPC. Inspect it before proceeding."

# Persist each resource ID immediately after successful creation.
umask 077
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

save_state() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value" >> "$STATE_FILE"
}

tag_resource() {
  local resource_id="$1" name="$2"
  aws ec2 create-tags --region "$REGION" \
    --resources "$resource_id" \
    --tags "Key=Name,Value=$name" "Key=Project,Value=$PROJECT"
}

echo "Creating dedicated VPC..."
VPC_ID="$(aws ec2 create-vpc \
  --region "$REGION" \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=Production-SSM-VPC},{Key=Project,Value=$PROJECT}]" \
  --query 'Vpc.VpcId' --output text)"
save_state VPC_ID "$VPC_ID"

aws ec2 modify-vpc-attribute --region "$REGION" \
  --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" \
  --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

echo "Waiting for VPC..."
aws ec2 wait vpc-available --region "$REGION" --vpc-ids "$VPC_ID"

echo "Creating public subnet..."
SUBNET_ID="$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone us-east-1a \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=Production-SSM-Public-Subnet-A},{Key=Project,Value=$PROJECT}]" \
  --query 'Subnet.SubnetId' --output text)"
save_state SUBNET_ID "$SUBNET_ID"

echo "Enabling public IPv4 assignment on the subnet..."
aws ec2 modify-subnet-attribute --region "$REGION" \
  --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

echo "Creating and attaching Internet Gateway..."
IGW_ID="$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=Production-SSM-IGW},{Key=Project,Value=$PROJECT}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)"
save_state IGW_ID "$IGW_ID"

aws ec2 attach-internet-gateway --region "$REGION" \
  --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "Creating public route table..."
ROUTE_TABLE_ID="$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=Production-SSM-Public-RT},{Key=Project,Value=$PROJECT}]" \
  --query 'RouteTable.RouteTableId' --output text)"
save_state ROUTE_TABLE_ID "$ROUTE_TABLE_ID"

aws ec2 create-route --region "$REGION" \
  --route-table-id "$ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null

aws ec2 associate-route-table --region "$REGION" \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_ID" >/dev/null

echo "Creating security group..."
SG_ID="$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name ssm-deployment-web-sg \
  --description "Project 2: HTTP web demo; no inbound SSH" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=Production-SSM-Web-SG},{Key=Project,Value=$PROJECT}]" \
  --query 'GroupId' --output text)"
save_state SG_ID "$SG_ID"

aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

echo
echo "NETWORK STAGE COMPLETE"
echo "VPC:         $VPC_ID"
echo "Subnet:      $SUBNET_ID"
echo "IGW:         $IGW_ID"
echo "Route table: $ROUTE_TABLE_ID"
echo "Security SG: $SG_ID"
echo "Resource IDs saved in $STATE_FILE"
echo "No EC2 instance has been launched."