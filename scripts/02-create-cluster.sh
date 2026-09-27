#!/usr/bin/env bash
# Provisions EKS (~15 min) with Container Insights and points kubectl at it.
source "$(dirname "$0")/common.sh"
if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  log "Creating EKS cluster $CLUSTER_NAME"
  eksctl create cluster -f "$ROOT_DIR/infra/cluster.yaml"
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes
