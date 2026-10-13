
#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_PAGER=""
REGION="us-east-1"
STATE_FILE="state.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f "$STATE_FILE" ]] || die "state.env not found."
source "$STATE_FILE"

: "${INSTANCE_ID:?INSTANCE_ID missing}"
: "${PUBLIC_IP:?PUBLIC_IP missing}"

echo "Checking SSM managed-node status..."
PING_STATUS="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"

[[ "$PING_STATUS" == "Online" ]] ||
  die "Instance is not Online in SSM (status: $PING_STATUS). Wait and retry."

echo "Sending Nginx deployment command through SSM..."

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "Project 2: Install Nginx and deploy demo webpage" \
  --parameters 'commands=[
    "set -e",
    "sudo apt-get update -y",
    "sudo apt-get install -y nginx",
    "sudo systemctl enable --now nginx",
    "printf '\''<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>SSM Deployment</title></head><body><h1>Deployed through AWS Systems Manager</h1><p>Project 2: EC2 deployment automation.</p></body></html>'\'' | sudo tee /var/www/html/index.html >/dev/null",
    "sudo nginx -t",
    "sudo systemctl is-active nginx"
  ]' \
  --query 'Command.CommandId' --output text)"

printf 'SSM_COMMAND_ID=%q\n' "$COMMAND_ID" >> "$STATE_FILE"

echo "SSM command ID: $COMMAND_ID"
echo "Waiting for command execution..."

for attempt in $(seq 1 30); do
  STATUS="$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || true)"

  case "$STATUS" in
    Success)
      echo "SSM deployment succeeded."
      break
      ;;
    Failed|Cancelled|TimedOut|Cancelling)
      echo "SSM deployment ended with status: $STATUS"
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
        --output json
      exit 1
      ;;
    *)
      sleep 5
      ;;
  esac
done

[[ "${STATUS:-}" == "Success" ]] || die "Timed out waiting for SSM command. Check invocation status."

echo
echo "DEPLOYMENT COMPLETE"
echo "Web address: http://$PUBLIC_IP"