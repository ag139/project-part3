# ReplicasMismatch

A deployment has had fewer available replicas than requested for 10 minutes.

## Impact

Capacity is reduced. If the count reaches zero the service is down. A rollout
that never completes also blocks later deployments.

## Narrow it down

    kubectl get pods -n devops-app -o wide
    kubectl describe deployment <name> -n devops-app
    kubectl get events -n devops-app --sort-by=.metadata.creationTimestamp | tail -20

| Pod state | Cause |
|---|---|
| `Pending` | No node has capacity, or a PVC is unbound |
| `ImagePullBackOff` | The tag does not exist or the registry credential is wrong |
| `CreateContainerConfigError` | A referenced Secret or ConfigMap is missing |
| `Running` but not ready | The readiness probe is failing |
| `CrashLoopBackOff` | See PodCrashLooping |

## Common cause in this project

After a cluster rebuild the application secrets are gone, so pods fail with
`CreateContainerConfigError`.

    kubectl get secrets -n devops-app

If `db-secrets` or `aws-secrets` is missing, `scripts/00-start.sh` recreates
them. Then restart the affected deployments.

    kubectl rollout restart deployment backend frontend worker postgres -n devops-app
