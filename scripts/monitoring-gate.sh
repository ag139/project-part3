#!/usr/bin/env sh
set -e

PROM="${PROM_URL:-http://monitoring-prometheus.observability.svc.cluster.local:9090}"
MAX_ERROR_RATIO="${MAX_ERROR_RATIO:-0.05}"
MAX_P95_SECONDS="${MAX_P95_SECONDS:-1}"
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"

echo "waiting ${SETTLE_SECONDS}s for metrics to settle after the rollout"
sleep "$SETTLE_SECONDS"

query() {
  wget -qO- "${PROM}/api/v1/query?query=$1" 2>/dev/null || echo ""
}

value_of() {
  echo "$1" | tr ',' '\n' | grep -A1 '"value"' | grep -o '"[0-9.e+-]*"' | tail -1 | tr -d '"'
}

echo "=== scrape targets ==="
RAW=$(query 'count(up{job=~"backend|jenkins"}==0)')
if ! echo "$RAW" | grep -q '"status":"success"'; then
  echo "MONITORING GATE FAILED: Prometheus is unreachable, the release cannot be verified"
  exit 1
fi
DOWN=$(value_of "$RAW")
DOWN="${DOWN:-0}"
if [ "$DOWN" != "0" ]; then
  echo "MONITORING GATE FAILED: ${DOWN} scrape target(s) are down"
  exit 1
fi
echo "all scrape targets are up"

echo "=== error ratio ==="
ERR=$(value_of "$(query 'app:error_rate5m')")
echo "5xx ratio over 5m: ${ERR:-no data yet}"
if [ -n "$ERR" ]; then
  if [ "$(awk -v e="$ERR" -v m="$MAX_ERROR_RATIO" 'BEGIN{print (e>m)?1:0}')" = "1" ]; then
    echo "MONITORING GATE FAILED: error ratio ${ERR} exceeds ${MAX_ERROR_RATIO}"
    exit 1
  fi
fi

echo "=== p95 latency ==="
LAT=$(value_of "$(query 'app:latency_p95_5m')")
echo "p95 latency over 5m: ${LAT:-no data yet}"
if [ -n "$LAT" ]; then
  if [ "$(awk -v l="$LAT" -v m="$MAX_P95_SECONDS" 'BEGIN{print (l>m)?1:0}')" = "1" ]; then
    echo "MONITORING GATE FAILED: p95 latency ${LAT}s exceeds ${MAX_P95_SECONDS}s"
    exit 1
  fi
fi

echo
echo "monitoring gate passed: the deployed release is serving traffic within objectives"
