#!/usr/bin/env bash
# Brings the environment back up after a host restart.
# Handles the kind control-plane IP problem automatically.
set -uo pipefail
cd "$(dirname "$0")/.."

C=devops-ci

sudo service docker start >/dev/null 2>&1
sudo service nginx stop >/dev/null 2>&1 || true
sudo sysctl -w fs.inotify.max_user_instances=8192 >/dev/null
sudo sysctl -w fs.inotify.max_user_watches=524288 >/dev/null
sleep 3

if ! docker ps -a --format '{{.Names}}' | grep -q "$C-control-plane"; then
  echo "no cluster found, creating one"
  ./scripts/01-setup-cluster.sh
  exit $?
fi

echo "starting control plane alone"
docker stop "$C-worker" "$C-worker2" >/dev/null 2>&1 || true
sleep 5
docker start "$C-control-plane" >/dev/null 2>&1
sleep 40

if docker ps --format '{{.Names}}' | grep -q "$C-control-plane"; then
  echo "control plane is up, starting workers"
  docker start "$C-worker" "$C-worker2" >/dev/null 2>&1
  sleep 40
  kind export kubeconfig --name "$C"
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
  kubectl get nodes
  echo
  echo "environment restored. Verify with: ./scripts/05-verify.sh"
else
  echo "control plane failed to start, rebuilding"
  kind delete cluster --name "$C"
  ./scripts/01-setup-cluster.sh
  echo
  echo "Cluster rebuilt. Now run:"
  echo "  source ~/.devops-env"
  echo "  export DOCKERHUB_USER=ayeletgeulayev"
  echo "  ./scripts/02-install-jenkins.sh"
fi
