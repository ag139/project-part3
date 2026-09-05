#!/usr/bin/env bash
# Stops the cluster in reverse order before the host is powered off.
# kind loses the control plane address when containers are killed abruptly.
set -uo pipefail
C=devops-ci

echo "stopping workers"
docker stop "$C-worker" "$C-worker2" >/dev/null 2>&1 || true
sleep 5

echo "stopping control plane"
docker stop "$C-control-plane" >/dev/null 2>&1 || true

echo
echo "cluster stopped cleanly. Run ./scripts/00-start.sh to bring it back."
