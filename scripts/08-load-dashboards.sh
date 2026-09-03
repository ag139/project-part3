#!/usr/bin/env bash
# Loads the dashboard JSON files from the repository into Grafana.
# The Grafana sidecar watches for ConfigMaps carrying the grafana_dashboard
# label, so a dashboard is defined by a file in Git and never by a manual
# import through the UI.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in observability/dashboards/*.json; do
  name=$(basename "$f" .json)
  echo "loading $name"
  kubectl create configmap "dashboard-$name" \
    --from-file="$(basename "$f")=$f" \
    -n observability --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply -f - >/dev/null
done

echo
kubectl get configmap -n observability -l grafana_dashboard=1
echo
echo "Grafana picks these up within about a minute."
