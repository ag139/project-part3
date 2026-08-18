#!/usr/bin/env bash
# Deploys the application for the first time, outside the CD pipeline.
# The CD pipeline handles every deployment after this one.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=devops-app
IMAGE_TAG="${1:?usage: $0 <image-tag>}"

echo "==> creating application secrets"
kubectl create secret generic db-secrets -n "$NS" \
  --from-literal=DB_USER=app \
  --from-literal=DB_PASSWORD="${DB_PASSWORD:-secret}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  kubectl create secret generic aws-secrets -n "$NS" \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "note: AWS credentials not set, S3 and SNS features will not work"
fi

echo "==> deploying with helm"
helm upgrade --install devops-app ./helm/devops-app \
  --namespace "$NS" \
  --set image.registry=ayeletgeulayev/ \
  --set image.tag="$IMAGE_TAG" \
  --wait --timeout 8m

kubectl get pods -n "$NS" -o wide
