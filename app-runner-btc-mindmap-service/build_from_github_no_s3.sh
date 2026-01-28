#!/usr/bin/env bash
set -euo pipefail

# Build and push the image to ECR using AWS CodeBuild with a GitHub source.
# No Copilot, no S3 staging, and no local Docker engine required.
# Prereq (once): import a GitHub token for CodeBuild
#   aws codebuild import-source-credentials \
#     --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token <GITHUB_PAT>

PROFILE="${AWS_PROFILE:-app-runner}"
REGION="${AWS_REGION:-us-east-2}"

SERVICE_NAME="${SERVICE_NAME:-btc-mindmap-service}"
ECR_REPO="${ECR_REPO:-btc-mindmap-service}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Required: Git repo URL (HTTPS or SSH) and branch
REPO_URL="${REPO_URL:?Set REPO_URL to your GitHub repo URL (https or ssh)}"
BRANCH="${BRANCH:-main}"

# Path to buildspec inside the repo (default: buildspec.yml at repo root)
BUILD_SPEC_PATH="${BUILD_SPEC_PATH:-buildspec.yml}"

CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-btc-mindmap-github-build}"
CODEBUILD_ROLE_NAME="${CODEBUILD_ROLE_NAME:-codebuild-btc-mindmap-role}"

awscli() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd aws

ACCOUNT_ID="$(awscli sts get-caller-identity --query Account --output text)"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
IMAGE_URI="$ECR_URI:$IMAGE_TAG"

echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo "Account: $ACCOUNT_ID"
echo "Repo:    $REPO_URL @$BRANCH"
echo "Image:   $IMAGE_URI"

echo "\n==> Ensure ECR repo exists: $ECR_REPO"
awscli ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 \
  || awscli ecr create-repository --repository-name "$ECR_REPO" >/dev/null

echo "\n==> Ensure CodeBuild role exists: $CODEBUILD_ROLE_NAME"
if ! awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" >/dev/null 2>&1; then
  cat > /tmp/cb-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
  awscli iam create-role --role-name "$CODEBUILD_ROLE_NAME" --assume-role-policy-document file:///tmp/cb-trust.json >/dev/null
fi

cat > /tmp/cb-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeRepositories"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
JSON

awscli iam put-role-policy \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --policy-name "codebuild-btc-mindmap-inline" \
  --policy-document file:///tmp/cb-policy.json >/dev/null

CODEBUILD_ROLE_ARN="$(awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" --query 'Role.Arn' --output text)"

echo "\n==> Ensure CodeBuild project exists: $CODEBUILD_PROJECT"
if ! awscli codebuild batch-get-projects --names "$CODEBUILD_PROJECT" --query 'projects[0].name' --output text 2>/dev/null | grep -q "$CODEBUILD_PROJECT"; then
  awscli codebuild create-project \
    --name "$CODEBUILD_PROJECT" \
    --service-role "$CODEBUILD_ROLE_ARN" \
    --source "type=GITHUB,location=$REPO_URL,gitCloneDepth=1,buildspec=$BUILD_SPEC_PATH" \
    --source-version "$BRANCH" \
    --artifacts type=NO_ARTIFACTS \
    --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true" \
    --timeout-in-minutes 20 \
    --queued-timeout-in-minutes 60 \
    --environment-variables \
      "name=AWS_REGION,value=$REGION,type=PLAINTEXT" \
      "name=ECR_URI,value=$ECR_URI,type=PLAINTEXT" \
      "name=IMAGE_URI,value=$IMAGE_URI,type=PLAINTEXT" \
      "name=IMAGE_TAG,value=$IMAGE_TAG,type=PLAINTEXT" >/dev/null
fi

echo "\n==> Start CodeBuild build from GitHub (no S3, no local Docker)"
BUILD_ID="$(awscli codebuild start-build \
  --project-name "$CODEBUILD_PROJECT" \
  --source-version "$BRANCH" \
  --environment-variables-override \
    name=IMAGE_TAG,value="$IMAGE_TAG",type=PLAINTEXT \
    name=IMAGE_URI,value="$IMAGE_URI",type=PLAINTEXT \
  --query 'build.id' --output text)"

echo "Build started: $BUILD_ID"

echo "\n==> Wait for CodeBuild completion"
while true; do
  STATUS="$(awscli codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)"
  echo "  Status: $STATUS"
  if [[ "$STATUS" == "SUCCEEDED" ]]; then
    break
  fi
  if [[ "$STATUS" == "FAILED" || "$STATUS" == "FAULT" || "$STATUS" == "STOPPED" || "$STATUS" == "TIMED_OUT" ]]; then
    echo "Build failed: $STATUS" >&2
    LOGS="$(awscli codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].logs.deepLink' --output text)"
    echo "Logs: $LOGS" >&2
    exit 1
  fi
  sleep 10
done

echo "\n==> Image is ready: $IMAGE_URI"
