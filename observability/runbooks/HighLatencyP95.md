# HighLatencyP95

The 95th percentile request duration has been above 1 second for 10 minutes.

## Impact

The service answers but slowly. One request in twenty is worse than the
threshold. Users notice this before any error appears.

## Narrow it down

| Observation | Likely cause |
|---|---|
| p50 flat, p95 and p99 rising | A subset of requests is slow, often database or storage |
| All percentiles rising together | Resource starvation across the board |
| CPU throttling visible on the Kubernetes dashboard | The CPU limit is too low for the load |
| Latency rose at a version change | The release itself |

## Queries

    app:latency_p95_5m
    histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="devops-app"}[5m])))
    histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="devops-app"}[5m])))
    sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="devops-app"}[5m]))

## Actions

Throttling present: raise the CPU limit in `helm/devops-app/values.yaml` and
deploy through the CD pipeline.

Load related: scale out.

    kubectl scale deployment backend -n devops-app --replicas=4

Release related: roll back as described in HighErrorRate.
