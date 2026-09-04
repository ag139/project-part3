# PrometheusTargetDown

Prometheus has been unable to scrape a target for five minutes.

## Impact

This alert is about the monitoring system itself. While a target is down there
is no data for it, so every other alert about that component is silent. Absence
of alerts is not evidence of health.

## Narrow it down

Open Prometheus, Status, Target health.

    kubectl get servicemonitor -n observability
    kubectl get pods -n devops-app
    kubectl get pods -n jenkins

| Observation | Cause |
|---|---|
| The pods are gone | The workload is down, that is the real problem |
| Pods running, target missing | The ServiceMonitor selector no longer matches |
| Target present but failing | Wrong path or port, or the endpoint requires auth |
| Everything looks right | A NetworkPolicy is blocking the scrape |

## Verify the endpoint by hand

    kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 -n devops-app -- \
      curl -s http://backend:5000/metrics | head -5

    kubectl exec -n jenkins jenkins-0 -c jenkins -- \
      curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/prometheus/

The Jenkins path needs its trailing slash. Without it the request is redirected
and the scrape returns nothing.

## Actions

Selector drift: compare the ServiceMonitor selector with the Service labels.

    kubectl get svc backend -n devops-app --show-labels
    kubectl get servicemonitor devops-app-backend -n observability -o yaml

Reapply from Git rather than editing in place.

    kubectl apply -f observability/monitors/
