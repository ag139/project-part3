#!/usr/bin/env bash
# Removes the platform. Idempotent: missing pieces are skipped.
#   ./scripts/07-uninstall.sh          removes Jenkins and the application
#   ./scripts/07-uninstall.sh --all    also deletes the cluster
set -uo pipefail
cd "$(dirname "$0")/.."

ALL="${1:-}"
echo "This removes the Jenkins installation and the deployed application."
[ "$ALL" = "--all" ] && echo "It will also DELETE THE ENTIRE CLUSTER."
read -p "Type yes to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "aborted"; exit 0; }

helm uninstall devops-app -n devops-app 2>/dev/null || echo "  app not installed"
kubectl delete secret db-secrets aws-secrets -n devops-app --ignore-not-found
helm uninstall jenkins -n jenkins 2>/dev/null || echo "  jenkins not installed"
kubectl delete pvc jenkins -n jenkins --ignore-not-found
kubectl delete secret dockerhub-creds -n jenkins --ignore-not-found
kubectl delete -f jenkins/rbac/roles.yaml --ignore-not-found
kubectl delete -f jenkins/rbac/serviceaccounts.yaml --ignore-not-found
kubectl delete namespace devops-app --ignore-not-found

if [ "$ALL" = "--all" ]; then
  kind delete cluster --name devops-ci
  echo "Cluster deleted. Images in the registry are unaffected."
  echo "Revoke the Docker Hub token separately if it is no longer needed."
else
  echo "Jenkins and the application removed. Cluster still running."
  echo "To remove it too: ./scripts/07-uninstall.sh --all"
fi
