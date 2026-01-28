#!/usr/bin/env bash
set -euo pipefail

# One-click App Runner deploy using an existing ECR image.
# No Copilot, no S3, no local Docker.

PROFILE="${AWS_PROFILE:-app-runner}"
REGION="${AWS_REGION:-us-east-2}"

# Required: ECR image URI, e.g. 123456789012.dkr.ecr.us-east-2.amazonaws.com/btc-mindmap-service:20260128-1200
IMAGE_URI="${IMAGE_URI:?Set IMAGE_URI to your ECR image (e.g. ...:tag)}"

SERVICE_NAME="${SERVICE_NAME:-btc-mindmap-service}"
ECR_ACCESS_ROLE="${ECR_ACCESS_ROLE:-apprunner-ecr-access}"

# Instance settings
CPU="${CPU:-1 vCPU}"
MEMORY="${MEMORY:-2 GB}"
PORT="${PORT:-8080}"

awscli() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd aws

echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo "Service: $SERVICE_NAME"
echo "Image:   $IMAGE_URI"

echo "\n==> Ensure App Runner ECR access role exists: $ECR_ACCESS_ROLE"
if ! awscli iam get-role --role-name "$ECR_ACCESS_ROLE" >/dev/null 2>&1; then
  cat > /tmp/apprunner-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "build.apprunner.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
  awscli iam create-role \
    --role-name "$ECR_ACCESS_ROLE" \
    --assume-role-policy-document file:///tmp/apprunner-trust.json >/dev/null
  awscli iam attach-role-policy \
    --role-name "$ECR_ACCESS_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess >/dev/null
fi

ROLE_ARN="$(awscli iam get-role --role-name "$ECR_ACCESS_ROLE" --query 'Role.Arn' --output text)"

echo "\n==> Check if service exists"
SERVICE_ARN="$(awscli apprunner list-services --query 'ServiceSummaryList[?ServiceName==`'"$SERVICE_NAME"'`].ServiceArn' --output text)"

if [[ -z "$SERVICE_ARN" ]]; then
  echo "\n==> Create service"
  awscli apprunner create-service \
    --service-name "$SERVICE_NAME" \
    --source-configuration "{
      \"ImageRepository\": {
        \"ImageIdentifier\": \"$IMAGE_URI\",\"ImageRepositoryType\": \"ECR\",
        \"ImageConfiguration\": {\"Port\": \"$PORT\"}
      },
      \"AuthenticationConfiguration\": {\"AccessRoleArn\": \"$ROLE_ARN\"}
    }" \
    --instance-configuration "{\"Cpu\":\"$CPU\",\"Memory\":\"$MEMORY\"}" \
    >/dev/null
  echo "Created service: $SERVICE_NAME"
else
  echo "\n==> Update service"
  awscli apprunner update-service \
    --service-arn "$SERVICE_ARN" \
    --source-configuration "{
      \"ImageRepository\": {
        \"ImageIdentifier\": \"$IMAGE_URI\",\"ImageRepositoryType\": \"ECR\",
        \"ImageConfiguration\": {\"Port\": \"$PORT\"}
      },
      \"AuthenticationConfiguration\": {\"AccessRoleArn\": \"$ROLE_ARN\"}
    }" \
    >/dev/null
  echo "Updated service: $SERVICE_NAME"
fi

echo "\nDone. App Runner will pull $IMAGE_URI and deploy."
