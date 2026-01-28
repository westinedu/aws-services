#!/usr/bin/env bash
set -euo pipefail

# Single entrypoint: package local source -> CodeBuild builds/pushes to ECR -> App Runner deploys.
# No local Docker build. Uses dedicated S3 staging (auto-clean each run). No nested scripts.

PROFILE="${AWS_PROFILE:-app-runner}"
REGION="${AWS_REGION:-us-east-2}"

SERVICE_NAME="${SERVICE_NAME:-btc-mindmap-service}"    # App Runner service name
ECR_REPO="${ECR_REPO:-btc-mindmap-service}"           # ECR repository name
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"       # default: timestamp

CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-btc-mindmap-local-build}"
CODEBUILD_ROLE_NAME="${CODEBUILD_ROLE_NAME:-codebuild-btc-mindmap-role}"
APPRUNNER_ROLE_NAME="${APPRUNNER_ROLE_NAME:-apprunner-ecr-access}"

# App Runner instance settings
CPU="${CPU:-1 vCPU}"
MEMORY="${MEMORY:-2 GB}"
PORT="${PORT:-8080}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

awscli() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

need_cmd aws
need_cmd zip

ACCOUNT_ID="$(awscli sts get-caller-identity --query Account --output text)"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
IMAGE_URI="$ECR_URI:$IMAGE_TAG"

SRC_BUCKET_DEFAULT="ecr-src-$ACCOUNT_ID-$REGION"    # dedicated for ECR staging
SRC_BUCKET="${SRC_BUCKET:-$SRC_BUCKET_DEFAULT}"
SRC_KEY="${SRC_KEY:-services/$SERVICE_NAME/source-$IMAGE_TAG.zip}"

echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo "Account: $ACCOUNT_ID"
echo "Image:   $IMAGE_URI"
echo "Bucket:  s3://$SRC_BUCKET/$SRC_KEY (transient)"

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

echo "\n==> Ensure ECR repo exists"
awscli ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 \
	|| awscli ecr create-repository --repository-name "$ECR_REPO" >/dev/null

echo "\n==> Stage source (excluding node_modules/dist)"
STAGE_DIR="$tmpdir/stage"
mkdir -p "$STAGE_DIR"

cp "$ROOT_DIR/Dockerfile" "$STAGE_DIR/"
cp "$ROOT_DIR/package.json" "$STAGE_DIR/"
cp "$ROOT_DIR/package-lock.json" "$STAGE_DIR/" 2>/dev/null || true
cp "$ROOT_DIR/tsconfig.json" "$STAGE_DIR/"
cp "$ROOT_DIR/.dockerignore" "$STAGE_DIR/" 2>/dev/null || true
cp -R "$ROOT_DIR/src" "$STAGE_DIR/src"

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
if ! awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" >/dev/null 2>&1; then
	cat > "$tmpdir/cb-trust.json" <<'JSON'
{
	"Version": "2012-10-17",
	"Statement": [ { "Effect": "Allow", "Principal": { "Service": "codebuild.amazonaws.com" }, "Action": "sts:AssumeRole" } ]
}
JSON
	awscli iam create-role --role-name "$CODEBUILD_ROLE_NAME" --assume-role-policy-document file://"$tmpdir/cb-trust.json" >/dev/null
fi

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

awscli iam put-role-policy --role-name "$CODEBUILD_ROLE_NAME" --policy-name "codebuild-btc-mindmap-inline" --policy-document file://"$tmpdir/cb-policy.json" >/dev/null

CODEBUILD_ROLE_ARN="$(awscli iam get-role --role-name "$CODEBUILD_ROLE_NAME" --query 'Role.Arn' --output text)"

echo "\n==> Ensure CodeBuild project exists: $CODEBUILD_PROJECT"
if ! awscli codebuild batch-get-projects --names "$CODEBUILD_PROJECT" --query 'projects[0].name' --output text 2>/dev/null | grep -q "$CODEBUILD_PROJECT"; then
	awscli codebuild create-project \
		--name "$CODEBUILD_PROJECT" \
		--service-role "$CODEBUILD_ROLE_ARN" \
		--source type=S3,location="$SRC_BUCKET/$SRC_KEY" \
		--artifacts type=NO_ARTIFACTS \
		--environment type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true \
		--timeout-in-minutes 20 --queued-timeout-in-minutes 60 >/dev/null
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

echo "\n==> Ensure App Runner ECR access role exists: $APPRUNNER_ROLE_NAME"
if ! awscli iam get-role --role-name "$APPRUNNER_ROLE_NAME" >/dev/null 2>&1; then
	cat > "$tmpdir/apr-trust.json" <<'JSON'
{
	"Version": "2012-10-17",
	"Statement": [ { "Effect": "Allow", "Principal": { "Service": "build.apprunner.amazonaws.com" }, "Action": "sts:AssumeRole" } ]
}
JSON
	awscli iam create-role --role-name "$APPRUNNER_ROLE_NAME" --assume-role-policy-document file://"$tmpdir/apr-trust.json" >/dev/null
	awscli iam attach-role-policy --role-name "$APPRUNNER_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess >/dev/null
fi

APPRUNNER_ROLE_ARN="$(awscli iam get-role --role-name "$APPRUNNER_ROLE_NAME" --query 'Role.Arn' --output text)"
SERVICE_ARN="$(awscli apprunner list-services --query 'ServiceSummaryList[?ServiceName==`'"$SERVICE_NAME"'`].ServiceArn' --output text)"

if [[ -z "$SERVICE_ARN" ]]; then
	echo "\n==> Create App Runner service"
	awscli apprunner create-service \
		--service-name "$SERVICE_NAME" \
		--source-configuration "{
			\"ImageRepository\":{\"ImageIdentifier\":\"$IMAGE_URI\",\"ImageRepositoryType\":\"ECR\",\"ImageConfiguration\":{\"Port\":\"$PORT\"}},
			\"AuthenticationConfiguration\":{\"AccessRoleArn\":\"$APPRUNNER_ROLE_ARN\"}
		}" \
		--instance-configuration "{\"Cpu\":\"$CPU\",\"Memory\":\"$MEMORY\"}" >/dev/null
	echo "Service created: $SERVICE_NAME"
  SERVICE_ARN="$(awscli apprunner list-services --query 'ServiceSummaryList[?ServiceName==`'"$SERVICE_NAME"'`].ServiceArn' --output text)"
else
	echo "\n==> Update App Runner service"
	awscli apprunner update-service \
		--service-arn "$SERVICE_ARN" \
		--source-configuration "{
			\"ImageRepository\":{\"ImageIdentifier\":\"$IMAGE_URI\",\"ImageRepositoryType\":\"ECR\",\"ImageConfiguration\":{\"Port\":\"$PORT\"}},
			\"AuthenticationConfiguration\":{\"AccessRoleArn\":\"$APPRUNNER_ROLE_ARN\"}
		}" >/dev/null
	echo "Service updated: $SERVICE_NAME"
fi

SERVICE_URL="$(awscli apprunner describe-service --service-arn "$SERVICE_ARN" --query 'Service.ServiceUrl' --output text)"

echo "\nDone. Image deployed: $IMAGE_URI"
echo "App Runner URL: $SERVICE_URL"
