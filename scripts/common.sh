#!/usr/bin/env bash
# Shared settings. Override any of these via environment variables.
set -euo pipefail
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-coworking-cluster}"
export ECR_REPO="${ECR_REPO:-coworking}"
export CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-coworking-build}"
export GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/stvwng/cd12355-microservices-aws-kubernetes-project-starter.git}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
