#!/usr/bin/env bash
# Installs Jenkins with RBAC, agent templates and credentials, all from code.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DOCKERHUB_USER:?set DOCKERHUB_USER before running}"
: "${DOCKERHUB_TOKEN:?set DOCKERHUB_TOKEN before running}"

echo "==> creating namespaces, service accounts and RBAC"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f jenkins/rbac/serviceaccounts.yaml
kubectl apply -f jenkins/rbac/roles.yaml

echo "==> creating the registry credential as a Kubernetes secret"
kubectl delete secret dockerhub-creds -n jenkins --ignore-not-found
kubectl create secret generic dockerhub-creds -n jenkins \
  --from-literal=username="$DOCKERHUB_USER" \
  --from-literal=password="$DOCKERHUB_TOKEN"
kubectl label secret dockerhub-creds -n jenkins \
  "jenkins.io/credentials-type=usernamePassword" --overwrite
kubectl annotate secret dockerhub-creds -n jenkins \
  "jenkins.io/credentials-description=Docker Hub push credentials" --overwrite

echo "==> installing Jenkins"
helm repo add jenkins https://charts.jenkins.io >/dev/null
helm repo update >/dev/null
# Chart version is pinned so a reinstall reproduces the tested combination
# of chart, Jenkins core and plugin versions.
helm upgrade --install jenkins jenkins/jenkins \
  --version 5.9.54 \
  --namespace jenkins \
  --values jenkins/helm/values.yaml \
  --wait --timeout 15m

echo "==> Jenkins is ready"
kubectl get pods -n jenkins
echo
echo "admin password:"
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password && echo
echo
echo "open the UI with:"
echo "  kubectl port-forward -n jenkins svc/jenkins 8080:8080"
echo "then run the seed-job to create the CI and CD jobs."
