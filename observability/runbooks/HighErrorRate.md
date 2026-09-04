# HighErrorRate

More than 5 percent of requests returned a 5xx over the last 5 minutes.

## Impact

Users are seeing errors now. This is a symptom, not a cause.

## Narrow it down

Open the Application Overview dashboard.

| What the panels show | Likely cause |
|---|---|
| Dependency failures rising for `database` | Postgres unreachable or rejecting connections |
| Dependency failures rising for `s3` or `sns` | AWS credentials or connectivity |
| No dependency failures, errors on one endpoint | A code path in the new release |
| Errors started at a version change | The release itself |

## Queries

    app:error_rate5m
    sum by (endpoint, status) (rate(http_requests_total{namespace="devops-app",status=~"5.."}[5m]))
    sum by (dependency) (rate(dependency_failures_total{namespace="devops-app"}[5m]))
    app_info

## If a release caused it

    helm history devops-app -n devops-app
    helm rollback devops-app -n devops-app

Recovery is confirmed when `app:error_rate5m` falls under 0.05 and the version
panel shows the previous tag.

## If a dependency caused it

Rolling back will not help.

    kubectl logs -n devops-app -l component=backend --tail=50
    kubectl get pods -n devops-app
