#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> installing the monitoring stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace observability --create-namespace \
  --values observability/helm/values.yaml \
  --timeout 15m

echo "==> waiting for Prometheus"
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus -n observability --timeout=300s || true

echo "==> applying monitors, rules and policies"
kubectl apply -f observability/monitors/
kubectl apply -f observability/rules/
kubectl apply -f observability/networkpolicy.yaml

echo "==> loading dashboards"
./scripts/08-load-dashboards.sh

echo
echo "Grafana admin password:"
kubectl get secret monitoring-grafana -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
echo
echo "  kubectl port-forward -n observability svc/monitoring-grafana 3000:80"
echo "  kubectl port-forward -n observability svc/monitoring-prometheus 9090:9090"
