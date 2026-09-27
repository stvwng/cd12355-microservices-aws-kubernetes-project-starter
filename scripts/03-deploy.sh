#!/usr/bin/env bash
# Deploys (or upgrades) the stack. Usage: scripts/03-deploy.sh [IMAGE_TAG]
# With no tag, the newest image in ECR is released.
source "$(dirname "$0")/common.sh"
DEPLOY_DIR="$ROOT_DIR/deployment"

TAG="${1:-$(aws ecr describe-images --repository-name "$ECR_REPO" --region "$AWS_REGION" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)}"
if [[ -z "$TAG" || "$TAG" == "None" ]]; then
  echo "ERROR: no image tag given and none found in ECR repo $ECR_REPO; run a CodeBuild build first." >&2
  exit 1
fi
IMAGE="$REGISTRY/$ECR_REPO:$TAG"

log "Applying config, secret, and database"
kubectl apply -f "$DEPLOY_DIR/configmap.yaml" -f "$DEPLOY_DIR/secret.yaml" \
  -f "$DEPLOY_DIR/pv.yaml" -f "$DEPLOY_DIR/pvc.yaml" \
  -f "$DEPLOY_DIR/postgresql-deployment.yaml" -f "$DEPLOY_DIR/postgresql-service.yaml"
kubectl rollout status deploy/postgresql --timeout=300s

# Seed only an empty database so re-running deploys is safe.
POD=$(kubectl get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}')
PSQL='psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
if [[ "$(kubectl exec "$POD" -- sh -c "$PSQL -tAc \"select to_regclass('public.tokens') is not null\"")" != "t" ]]; then
  log "Seeding database"
  for f in "$ROOT_DIR"/db/*.sql; do
    kubectl exec -i "$POD" -- sh -c "$PSQL" < "$f" >/dev/null
  done
fi

# Record the released tag in the manifest so the repo reflects what is running.
sed -i.bak -E "s#^( *image: ).*/$ECR_REPO:.*#\1$IMAGE#; s#^( *image: )<AWS_ACCOUNT_ID>.*#\1$IMAGE#" "$DEPLOY_DIR/coworking.yaml"
rm -f "$DEPLOY_DIR/coworking.yaml.bak"
log "Releasing $IMAGE"
kubectl apply -f "$DEPLOY_DIR/coworking.yaml"
kubectl rollout status deploy/coworking --timeout=300s
kubectl get svc,pods
