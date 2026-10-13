
#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_PAGER=""
REGION="us-east-1"
PROJECT="aws-ssm-deployment"

# Exact IAM names created by this project.
ROLE_NAME="aws-ssm-deployment-ec2-role"
PROFILE_NAME="aws-ssm-deployment-ec2-profile"
POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 ||
  die "AWS CLI is not installed."

aws sts get-caller-identity >/dev/null ||
  die "AWS authentication failed. Re-authenticate first."

echo
echo "FULL CLEANUP: $PROJECT"
echo "Region: $REGION"
echo "This will terminate tagged project EC2 instances and delete"
echo "the project's IAM role/profile and tagged network resources."
echo "This action is destructive and cannot be automatically undone."
echo

read -r -p "Type DELETE-PROJECT-ALL to continue: " CONFIRM
[[ "$CONFIRM" == "DELETE-PROJECT-ALL" ]] ||
  die "Cancelled. No cleanup was performed."

# 1. Terminate only running or pending project-tagged instances.
INSTANCE_IDS="$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)"

if [[ -n "$INSTANCE_IDS" && "$INSTANCE_IDS" != "None" ]]; then
  for INSTANCE_ID in $INSTANCE_IDS; do
    echo "Terminating project instance: $INSTANCE_ID"
    aws ec2 terminate-instances \
      --region "$REGION" \
      --instance-ids "$INSTANCE_ID"
    echo "Waiting for $INSTANCE_ID to terminate..."
    aws ec2 wait instance-terminated \
      --region "$REGION" \
      --instance-ids "$INSTANCE_ID"
  done
else
  echo "No active project EC2 instances found."
fi

# 2. Remove the project's IAM instance profile and role.
# Only the exact names created for this project are targeted.
if aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then

  PROFILE_ROLES="$(aws iam get-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Roles[*].RoleName' \
    --output text)"

  for ATTACHED_ROLE in $PROFILE_ROLES; do
    if [[ "$ATTACHED_ROLE" == "$ROLE_NAME" ]]; then
      echo "Removing role $ROLE_NAME from instance profile"
      aws iam remove-role-from-instance-profile \
        --instance-profile-name "$PROFILE_NAME" \
        --role-name "$ROLE_NAME"
    else
      die "Unexpected role $ATTACHED_ROLE in $PROFILE_NAME. Inspect manually."
    fi
  done

  echo "Deleting instance profile $PROFILE_NAME"
  aws iam delete-instance-profile \
    --instance-profile-name "$PROFILE_NAME"
else
  echo "Project instance profile not found."
fi

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ATTACHED_POLICIES="$(aws iam list-attached-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text)"

  for ATTACHED_POLICY in $ATTACHED_POLICIES; do
    echo "Detaching policy $ATTACHED_POLICY"
    aws iam detach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn "$ATTACHED_POLICY"
  done

  INLINE_POLICIES="$(aws iam list-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'PolicyNames[*]' \
    --output text)"

  for INLINE_POLICY in $INLINE_POLICIES; do
    echo "Deleting inline policy $INLINE_POLICY"
    aws iam delete-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-name "$INLINE_POLICY"
  done

  echo "Deleting IAM role $ROLE_NAME"
  aws iam delete-role --role-name "$ROLE_NAME"
else
  echo "Project IAM role not found."
fi

# 3. Find the project's VPCs by ownership tag.
VPCS="$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[*].VpcId' \
  --output text)"

if [[ -z "$VPCS" || "$VPCS" == "None" ]]; then
  echo "No tagged project VPCs found."
else
  for VPC_ID in $VPCS; do
    echo
    echo "Cleaning project VPC: $VPC_ID"

    # Delete project-tagged security groups.
    SGS="$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
                "Name=tag:Project,Values=$PROJECT" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
      --output text)"

    for SG_ID in $SGS; do
      [[ -n "$SG_ID" && "$SG_ID" != "None" ]] || continue
      echo "Deleting security group $SG_ID"
      aws ec2 delete-security-group \
        --region "$REGION" --group-id "$SG_ID"
    done

    # Disassociate and delete project-tagged route tables.
    RTS="$(aws ec2 describe-route-tables \
      --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
                "Name=tag:Project,Values=$PROJECT" \
      --query 'RouteTables[*].RouteTableId' \
      --output text)"

    for RT_ID in $RTS; do
      [[ -n "$RT_ID" && "$RT_ID" != "None" ]] || continue

      ASSOCS="$(aws ec2 describe-route-tables \
        --region "$REGION" \
        --route-table-ids "$RT_ID" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
        --output text)"

      for ASSOC_ID in $ASSOCS; do
        [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]] || continue
        echo "Disassociating route table association $ASSOC_ID"
        aws ec2 disassociate-route-table \
          --region "$REGION" --association-id "$ASSOC_ID"
      done

      echo "Deleting route table $RT_ID"
      aws ec2 delete-route-table \
        --region "$REGION" --route-table-id "$RT_ID"
    done

    # Detach and delete project-tagged Internet Gateways.
    IGWS="$(aws ec2 describe-internet-gateways \
      --region "$REGION" \
      --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
                "Name=tag:Project,Values=$PROJECT" \
      --query 'InternetGateways[*].InternetGatewayId' \
      --output text)"

    for IGW_ID in $IGWS; do
      [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]] || continue
      echo "Detaching Internet Gateway $IGW_ID"
      aws ec2 detach-internet-gateway \
        --region "$REGION" \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID"

      echo "Deleting Internet Gateway $IGW_ID"
      aws ec2 delete-internet-gateway \
        --region "$REGION" --internet-gateway-id "$IGW_ID"
    done

    # Delete project-tagged subnets.
    SUBNETS="$(aws ec2 describe-subnets \
      --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
                "Name=tag:Project,Values=$PROJECT" \
      --query 'Subnets[*].SubnetId' \
      --output text)"

    for SUBNET_ID in $SUBNETS; do
      [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]] || continue
      echo "Deleting subnet $SUBNET_ID"
      aws ec2 delete-subnet \
        --region "$REGION" --subnet-id "$SUBNET_ID"
    done

    echo "Deleting project VPC $VPC_ID"
    aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
  done
fi

echo
echo "Cleanup commands completed."
echo "Run the independent verification checks before considering cleanup complete."