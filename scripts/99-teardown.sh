#!/usr/bin/env bash
# Deletes billable resources. EKS control plane + nodes + load balancer are the main costs.
source "$(dirname "$0")/common.sh"
kubectl delete -f "$ROOT_DIR/deployment/coworking.yaml" --ignore-not-found || true  # releases the ELB first
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
if [[ "${DELETE_CI:-false}" == "true" ]]; then
  aws codebuild delete-project --name "$CODEBUILD_PROJECT"
  aws ecr delete-repository --repository-name "$ECR_REPO" --force --region "$AWS_REGION"
fi
