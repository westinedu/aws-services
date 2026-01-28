#!/bin/bash
#
# deploy.sh -- One‑click deployment of the Bitcoin price service to AWS App Runner
#
# This script builds a Docker image for the Flask Bitcoin price API,
# pushes it to Amazon Elastic Container Registry (ECR), and creates
# an AWS App Runner service referencing the image.  It uses the AWS
# Command Line Interface (CLI) and Docker.  Before running this
# script you must:
#   1. Install and configure the AWS CLI with appropriate
#      credentials and default region (`aws configure`).
#   2. Install Docker and ensure the daemon is running.
#   3. Optionally adjust SERVICE_NAME, REGION and IMAGE_TAG below.
#
# The script creates a source‑configuration JSON file on the fly
# similar to the example used in the official App Runner example
# repository【693152069355980†L321-L337】 and then calls
# `aws apprunner create-service` to deploy the container.  See the
# Stackademic article (Feb 2024) for an overview of this CLI
# invocation【237839028027661†L79-L87】.

set -euo pipefail

# Change these variables to suit your environment.
SERVICE_NAME="btc-price-service"
REGION="us-east-1"
IMAGE_TAG="latest"

# Determine AWS account ID via STS.  If this fails, ensure your
# credentials are configured.  The account ID is needed to construct
# the ECR registry URL.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ECR repository name defaults to the service name.  You can change
# this if you want to push to a different repository.
REPO_NAME="$SERVICE_NAME"

echo "Building Docker image…"
docker build -t "$REPO_NAME:$IMAGE_TAG" .

# Ensure the ECR repository exists.  If describe‑repositories fails
# this call will create the repository.
if ! aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Creating ECR repository $REPO_NAME in region $REGION"
  aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" >/dev/null
fi

REGISTRY_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
FULL_IMAGE="${REGISTRY_URL}/${REPO_NAME}:${IMAGE_TAG}"

echo "Logging in to ECR…"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL"

echo "Tagging and pushing Docker image to $FULL_IMAGE…"
docker tag "$REPO_NAME:$IMAGE_TAG" "$FULL_IMAGE"
docker push "$FULL_IMAGE"

echo "Generating App Runner source configuration…"
cat > source-configuration.json <<EOF
{
  "ImageRepository": {
    "ImageIdentifier": "$FULL_IMAGE",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "8000"
    }
  },
  "AutoDeploymentsEnabled": false
}
EOF

echo "Creating AWS App Runner service…"
aws apprunner create-service \
  --service-name "$SERVICE_NAME" \
  --source-configuration file://source-configuration.json \
  --region "$REGION"

echo "Deployment initiated.  Use the AWS console or CLI to check the status."