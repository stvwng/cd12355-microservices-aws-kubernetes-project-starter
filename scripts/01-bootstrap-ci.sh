#!/usr/bin/env bash
# Creates the ECR repository and a CodeBuild project that builds on every push to main.
source "$(dirname "$0")/common.sh"

log "Creating ECR repository $ECR_REPO"
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" \
       --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE >/dev/null
# Keep storage costs bounded: only the 10 most recent images are retained.
aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --region "$AWS_REGION" --lifecycle-policy-text '{
  "rules":[{"rulePriority":1,"description":"keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' >/dev/null

ROLE_NAME="${CODEBUILD_PROJECT}-role"
log "Creating IAM role $ROLE_NAME"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  sleep 10  # IAM is eventually consistent; CodeBuild rejects a role it can't see yet.
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name codebuild-ecr-push --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":\"ecr:GetAuthorizationToken\",\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"codeconnections:GetConnectionToken\",\"codeconnections:GetConnection\",\"codestar-connections:GetConnectionToken\",\"codestar-connections:GetConnection\"],
     \"Resource\":[\"arn:aws:codeconnections:$AWS_REGION:$AWS_ACCOUNT_ID:connection/*\",\"arn:aws:codestar-connections:$AWS_REGION:$AWS_ACCOUNT_ID:connection/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"ecr:BatchCheckLayerAvailability\",\"ecr:InitiateLayerUpload\",\"ecr:UploadLayerPart\",\"ecr:CompleteLayerUpload\",\"ecr:PutImage\",\"ecr:BatchGetImage\"],
     \"Resource\":\"arn:aws:ecr:$AWS_REGION:$AWS_ACCOUNT_ID:repository/$ECR_REPO\"}]}"
# Give the policy change time to propagate before CodeBuild validates the role against the connection.
sleep 10
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

ENV_JSON="{\"type\":\"LINUX_CONTAINER\",\"image\":\"aws/codebuild/amazonlinux-x86_64-standard:5.0\",\"computeType\":\"BUILD_GENERAL1_SMALL\",\"privilegedMode\":true,
  \"environmentVariables\":[{\"name\":\"AWS_ACCOUNT_ID\",\"value\":\"$AWS_ACCOUNT_ID\"},{\"name\":\"IMAGE_REPO_NAME\",\"value\":\"$ECR_REPO\"}]}"
# CodeBuild authenticates to GitHub through a CodeConnections GitHub App connection when one is given.
if [[ -n "${CONNECTION_ARN:-}" ]]; then
  AUTH_JSON=",\"auth\":{\"type\":\"CODECONNECTIONS\",\"resource\":\"$CONNECTION_ARN\"}"
else
  AUTH_JSON=""
fi
SOURCE_JSON="{\"type\":\"GITHUB\",\"location\":\"$GITHUB_REPO_URL\",\"buildspec\":\"buildspec.yml\"$AUTH_JSON}"

log "Creating CodeBuild project $CODEBUILD_PROJECT"
if aws codebuild batch-get-projects --names "$CODEBUILD_PROJECT" --query 'projects[0].name' --output text | grep -q "$CODEBUILD_PROJECT"; then
  aws codebuild update-project --name "$CODEBUILD_PROJECT" --source "$SOURCE_JSON" --environment "$ENV_JSON" --service-role "$ROLE_ARN" >/dev/null
else
  aws codebuild create-project --name "$CODEBUILD_PROJECT" --source "$SOURCE_JSON" --source-version main \
    --artifacts type=NO_ARTIFACTS --environment "$ENV_JSON" --service-role "$ROLE_ARN" >/dev/null
fi

# The webhook is what makes builds start automatically on `git push`.
# Requires GitHub credentials registered with CodeBuild (console "Connect to GitHub", or
# `aws codebuild import-source-credentials --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token ...`).
log "Creating GitHub webhook (push to main)"
aws codebuild create-webhook --project-name "$CODEBUILD_PROJECT" \
  --filter-groups '[[{"type":"EVENT","pattern":"PUSH"},{"type":"HEAD_REF","pattern":"^refs/heads/main$"}]]' >/dev/null 2>&1 \
  || log "Webhook exists or GitHub credentials are missing; set CONNECTION_ARN and re-run."
log "Done. Registry: $REGISTRY/$ECR_REPO"
