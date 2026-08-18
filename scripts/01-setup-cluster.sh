#!/usr/bin/env bash
# Creates the multi-node kind cluster and installs the ingress controller.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER_NAME=devops-ci

echo "==> raising inotify limits (required on WSL for a multi-node cluster)"
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w fs.inotify.max_user_watches=524288

echo "==> creating the cluster"
kind create cluster --config jenkins/kind-cluster.yaml

echo "==> waiting for all nodes to be ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes

echo "==> installing the ingress controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set-string controller.nodeSelector."ingress-ready"=true \
  --set-string controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set-string controller.tolerations[0].operator=Equal \
  --set-string controller.tolerations[0].effect=NoSchedule

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> cluster is ready"
