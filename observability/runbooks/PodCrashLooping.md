# PodCrashLooping

A container restarted more than three times in fifteen minutes.

## Impact

The pod is not serving. Kubernetes keeps restarting it with an increasing
backoff, so the gap between attempts grows.

## The one command that matters

    kubectl logs <pod> -n devops-app --previous

Without `--previous` you see the container that has not crashed yet, not the
one that did. This is the single most common mistake when debugging a crash
loop.

## Then

    kubectl describe pod <pod> -n devops-app
    kubectl get events -n devops-app --sort-by=.metadata.creationTimestamp | tail -20

| Log content | Cause |
|---|---|
| `KeyError` on an environment variable | A ConfigMap key or Secret is missing |
| Connection refused to postgres | The database is not ready yet |
| `Read-only file system` | The container wrote outside its `/tmp` mount |
| `Permission denied` | Something tried to run as root |
| Killed with no message | Out of memory, check the limit |

## Actions

Missing configuration: fix the ConfigMap or Secret, then restart the deployment.

Out of memory: raise the memory limit in `helm/devops-app/values.yaml` and
deploy through CD.

Bad release: roll back as described in HighErrorRate.
