#!/usr/bin/env bash
# Collects the command outputs required as submission evidence.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=evidence
mkdir -p "$OUT"

echo "==> collecting cluster and Jenkins state"
{
  echo "=== nodes ==="
  kubectl get nodes -o wide
  echo
  echo "=== namespaces ==="
  kubectl get namespaces
  echo
  echo "=== jenkins ==="
  kubectl get pods,svc,pvc -n jenkins -o wide
  echo
  echo "=== jenkins rbac ==="
  kubectl get serviceaccount,role,rolebinding -n jenkins
  echo
  echo "=== deployer rbac in the application namespace ==="
  kubectl get role,rolebinding -n devops-app
  echo
  echo "=== application ==="
  kubectl get pods,svc,ingress -n devops-app -o wide
  echo
  echo "=== running images ==="
  kubectl get pods -n devops-app -o jsonpath='{..image}' | tr ' ' '\n' | sort -u
  echo
  echo "=== helm releases ==="
  helm list -A
  echo
  echo "=== application release history ==="
  helm history devops-app -n devops-app
} > "$OUT/00-cluster-state.txt"

echo "==> written to $OUT/00-cluster-state.txt"
ls -la "$OUT"
