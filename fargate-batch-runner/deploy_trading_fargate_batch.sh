#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-app-runner}"
REGION="${AWS_REGION:-us-east-2}"

SERVICE_NAME="${SERVICE_NAME:-trading-batch-runner}"
ECR_REPO="${ECR_REPO:-trading-batch-runner}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"

CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-trading-batch-local-build}"
CODEBUILD_ROLE_NAME="${CODEBUILD_ROLE_NAME:-codebuild-trading-batch-role}"

CLUSTER_NAME="${CLUSTER_NAME:-trading-batch-cluster}"
TASK_FAMILY="${TASK_FAMILY:-trading-batch-task}"
CONTAINER_NAME="${CONTAINER_NAME:-trading-batch}"
LOG_GROUP="${LOG_GROUP:-/ecs/trading-batch}"

CPU="${CPU:-512}"
MEMORY="${MEMORY:-1024}"

TRADING_BASE_URL="${TRADING_BASE_URL:-https://jwep53paj2.us-east-2.awsapprunner.com}"
TRADING_SYMBOLS="${TRADING_SYMBOLS:-AAPL,MSFT,GOOGL,AMZN,META,NVDA,AMD,TSLA,AVGO,NFLX}"
TRADING_TICKERS_S3_URI="${TRADING_TICKERS_S3_URI:-s3://s3-trading-data-bucket/config/us_tickers.json}"
TRADING_YEARS="${TRADING_YEARS:-3}"
TRADING_INCREMENTAL="${TRADING_INCREMENTAL:-true}"
TRADING_FILL_YEAR="${TRADING_FILL_YEAR:-false}"
TRADING_YEAR="${TRADING_YEAR:-}"
TRADING_END="${TRADING_END:-}"
BATCH_SIZE="${BATCH_SIZE:-50}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

awscli() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

need_cmd aws
need_cmd zip

ACCOUNT_ID="$(awscli sts get-caller-identity --query Account --output text)"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
IMAGE_URI="$ECR_URI:$IMAGE_TAG"

SRC_BUCKET_DEFAULT="ecr-src-$ACCOUNT_ID-$REGION"
SRC_BUCKET="${SRC_BUCKET:-$SRC_BUCKET_DEFAULT}"
SRC_KEY="${SRC_KEY:-services/$SERVICE_NAME/source-$IMAGE_TAG.zip}"

echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo "Account: $ACCOUNT_ID"
echo "Image:   $IMAGE_URI"
echo "Bucket:  s3://$SRC_BUCKET/$SRC_KEY (transient)"
echo "Tickers: $TRADING_TICKERS_S3_URI"

tmpdir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmpdir"
  awscli s3 rm "s3://$SRC_BUCKET/$SRC_KEY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "\n==> Ensure S3 source bucket exists"
if ! awscli s3api head-bucket --bucket "$SRC_BUCKET" >/dev/null 2>&1; then
  if [[ "$REGION" == "us-east-1" ]]; then
    awscli s3api create-bucket --bucket "$SRC_BUCKET" >/dev/null
  else
    awscli s3api create-bucket --bucket "$SRC_BUCKET" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
fi

echo "\n==> Ensure ticker list exists in S3"
TICKER_BUCKET="${TRADING_TICKERS_S3_URI#s3://}"
TICKER_BUCKET="${TICKER_BUCKET%%/*}"
TICKER_KEY="${TRADING_TICKERS_S3_URI#s3://*/}"
if [[ -n "$TICKER_BUCKET" && -n "$TICKER_KEY" ]]; then
  if ! awscli s3api head-object --bucket "$TICKER_BUCKET" --key "$TICKER_KEY" >/dev/null 2>&1; then
    TICKER_PAYLOAD=$(python3 - <<PY
import json
symbols = [s.strip().upper() for s in "${TRADING_SYMBOLS}".split(",") if s.strip()]
print(json.dumps(symbols))
PY
)
    printf "%s" "$TICKER_PAYLOAD" | awscli s3 cp - "s3://$TICKER_BUCKET/$TICKER_KEY" --content-type application/json >/dev/null
    echo "Created ticker list: s3://$TICKER_BUCKET/$TICKER_KEY"
  else
    echo "Ticker list exists: s3://$TICKER_BUCKET/$TICKER_KEY"
  fi
fi

echo "\n==> Ensure ECR repo exists"
awscli ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 \
  || awscli ecr create-repository --repository-name "$ECR_REPO" >/dev/null

echo "\n==> Stage source"
STAGE_DIR="$tmpdir/stage"
mkdir -p "$STAGE_DIR"

cp "$ROOT_DIR/Dockerfile" "$STAGE_DIR/"
cp "$ROOT_DIR/requirements.txt" "$STAGE_DIR/"
cp "$ROOT_DIR/run_batch.py" "$STAGE_DIR/"

cat > "$STAGE_DIR/buildspec.yml" <<'YML'
version: 0.2
phases:
  pre_build:
    commands:
      - echo "Login ECR"
      - aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}
  build:
    commands:
      - echo "Build & push ${IMAGE_URI}"
      - docker build -t ${IMAGE_URI} .
      - docker push ${IMAGE_URI}
artifacts:
  files:
    - '**/*'
  discard-paths: yes
YML

ZIP_PATH="$tmpdir/source.zip"
(cd "$STAGE_DIR" && zip -qr "$ZIP_PATH" .)

echo "\n==> Upload source to S3"
awscli s3 cp "$ZIP_PATH" "s3://$SRC_BUCKET/$SRC_KEY" >/dev/null

echo "\n==> Ensure CodeBuild role exists: $CODEBUILD_ROLE_NAME"
cat > "$tmpdir/cb-trust.json" <<'JSON'
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

if ! awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" >/dev/null 2>&1; then
  awscli iam create-role --role-name "$CODEBUILD_ROLE_NAME" --assume-role-policy-document file://"$tmpdir/cb-trust.json" >/dev/null
else
  awscli iam update-assume-role-policy --role-name "$CODEBUILD_ROLE_NAME" --policy-document file://"$tmpdir/cb-trust.json" >/dev/null
fi
sleep 5

cat > "$tmpdir/cb-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":[
      "ecr:GetAuthorizationToken","ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload",
      "ecr:UploadLayerPart","ecr:InitiateLayerUpload","ecr:PutImage","ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer","ecr:DescribeRepositories"
    ],"Resource":"*"},
    {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"},
    {"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::$SRC_BUCKET/$SRC_KEY"}
  ]
}
JSON

awscli iam put-role-policy --role-name "$CODEBUILD_ROLE_NAME" --policy-name "codebuild-trading-batch-inline" --policy-document file://"$tmpdir/cb-policy.json" >/dev/null

CODEBUILD_ROLE_ARN="$(awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" --query 'Role.Arn' --output text)"

echo "\n==> Ensure CodeBuild project exists: $CODEBUILD_PROJECT"
if ! awscli codebuild batch-get-projects --names "$CODEBUILD_PROJECT" --query 'projects[0].name' --output text 2>/dev/null | grep -q "$CODEBUILD_PROJECT"; then
  awscli codebuild create-project \
    --name "$CODEBUILD_PROJECT" \
    --service-role "$CODEBUILD_ROLE_ARN" \
    --source type=S3,location="$SRC_BUCKET/$SRC_KEY" \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true \
    --timeout-in-minutes 60 --queued-timeout-in-minutes 60 >/dev/null
fi

echo "\n==> Start CodeBuild"
BUILD_ID="$(awscli codebuild start-build \
  --project-name "$CODEBUILD_PROJECT" \
  --source-location-override "$SRC_BUCKET/$SRC_KEY" \
  --environment-variables-override \
    name=AWS_REGION,value="$REGION",type=PLAINTEXT \
    name=ECR_URI,value="$ECR_URI",type=PLAINTEXT \
    name=IMAGE_URI,value="$IMAGE_URI",type=PLAINTEXT \
  --query 'build.id' --output text)"

echo "Build started: $BUILD_ID"
while true; do
  STATUS="$(awscli codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)"
  echo "  Status: $STATUS"
  if [[ "$STATUS" == "SUCCEEDED" ]]; then break; fi
  if [[ "$STATUS" == "FAILED" || "$STATUS" == "FAULT" || "$STATUS" == "STOPPED" || "$STATUS" == "TIMED_OUT" ]]; then
    LOGS="$(awscli codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].logs.deepLink' --output text)"
    echo "Build failed: $STATUS" >&2
    echo "Logs: $LOGS" >&2
    exit 1
  fi
  sleep 10
done

# --- ECS/Fargate ---

echo "\n==> Ensure ECS cluster exists: $CLUSTER_NAME"
if ! awscli ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  awscli ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null
fi

echo "\n==> Ensure ECS task execution role exists"
EXEC_ROLE_NAME="ecsTaskExecutionRole"
if ! awscli iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  cat > "$tmpdir/ecs-exec-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" } ]
}
JSON
  awscli iam create-role --role-name "$EXEC_ROLE_NAME" --assume-role-policy-document file://"$tmpdir/ecs-exec-trust.json" >/dev/null
  awscli iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
fi
EXEC_ROLE_ARN="$(awscli iam get-role --role-name "$EXEC_ROLE_NAME" --query 'Role.Arn' --output text)"

TASK_ROLE_NAME="${TASK_ROLE_NAME:-trading-batch-task-role}"
if ! awscli iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1; then
  cat > "$tmpdir/ecs-task-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" } ]
}
JSON
  awscli iam create-role --role-name "$TASK_ROLE_NAME" --assume-role-policy-document file://"$tmpdir/ecs-task-trust.json" >/dev/null
fi

TASK_ROLE_ARN="$(awscli iam get-role --role-name "$TASK_ROLE_NAME" --query 'Role.Arn' --output text)"

if [[ -n "$TRADING_TICKERS_S3_URI" ]]; then
  TICKER_BUCKET="${TRADING_TICKERS_S3_URI#s3://}"
  TICKER_BUCKET="${TICKER_BUCKET%%/*}"
  TICKER_KEY="${TRADING_TICKERS_S3_URI#s3://*/}"
  if [[ -n "$TICKER_BUCKET" && -n "$TICKER_KEY" ]]; then
    cat > "$tmpdir/ecs-task-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::$TICKER_BUCKET/$TICKER_KEY"}
  ]
}
JSON
    awscli iam put-role-policy --role-name "$TASK_ROLE_NAME" --policy-name "trading-batch-s3-tickers" --policy-document file://"$tmpdir/ecs-task-policy.json" >/dev/null
  fi
fi

awscli logs create-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true

# Resolve default VPC, subnets, and security group
VPC_ID="$(awscli ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SUBNET_IDS="$(awscli ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].SubnetId' --output text)"
SG_ID="$(awscli ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)"

SUBNET_JSON="$(printf '"%s",' $SUBNET_IDS | sed 's/,$//')"

cat > "$tmpdir/taskdef.json" <<JSON
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "$CPU",
  "memory": "$MEMORY",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "$CONTAINER_NAME",
      "image": "$IMAGE_URI",
      "essential": true,
      "environment": [
        {"name": "TRADING_BASE_URL", "value": "$TRADING_BASE_URL"},
        {"name": "TRADING_SYMBOLS", "value": "$TRADING_SYMBOLS"},
        {"name": "TRADING_TICKERS_S3_URI", "value": "$TRADING_TICKERS_S3_URI"},
        {"name": "TRADING_YEARS", "value": "$TRADING_YEARS"},
        {"name": "TRADING_INCREMENTAL", "value": "$TRADING_INCREMENTAL"},
        {"name": "TRADING_FILL_YEAR", "value": "$TRADING_FILL_YEAR"},
        {"name": "TRADING_YEAR", "value": "$TRADING_YEAR"},
        {"name": "TRADING_END", "value": "$TRADING_END"},
        {"name": "BATCH_SIZE", "value": "$BATCH_SIZE"},
        {"name": "SLEEP_SECONDS", "value": "$SLEEP_SECONDS"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "$CONTAINER_NAME"
        }
      }
    }
  ]
}
JSON

echo "\n==> Register task definition"
TASK_DEF_ARN="$(awscli ecs register-task-definition --cli-input-json file://"$tmpdir/taskdef.json" --query 'taskDefinition.taskDefinitionArn' --output text)"

echo "\n==> Run task"
awscli ecs run-task \
  --cluster "$CLUSTER_NAME" \
  --launch-type FARGATE \
  --task-definition "$TASK_DEF_ARN" \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_JSON}],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
  --count 1 >/dev/null

echo "Done. Task started in cluster: $CLUSTER_NAME"
