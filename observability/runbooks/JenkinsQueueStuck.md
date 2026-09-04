# JenkinsQueueStuck

More than three builds have been queued for over ten minutes.

## Impact

Delivery is blocked. Nothing reaches production while the queue is stuck, and
the delay grows with every new commit.

## Narrow it down

Open the Jenkins and Delivery dashboard.

    kubectl get pods -n jenkins
    kubectl get events -n jenkins --sort-by=.metadata.creationTimestamp | tail -20

| Observation | Cause |
|---|---|
| No agent pods appear at all | The controller cannot create pods, check its RBAC |
| Agent pods `Pending` | The cluster has no capacity |
| Agent pods `ImagePullBackOff` | An agent container image tag is wrong |
| Agents start then die immediately | The agent cannot reach the controller |

## Queries

    jenkins_queue_size_value
    jenkins_executor_in_use_value
    jenkins_node_online_value

## Actions

Capacity: check node resources, and stop unrelated workloads if needed.

    kubectl top nodes

Controller wedged: recreate it. Job history survives on the persistent volume.

    kubectl delete pod jenkins-0 -n jenkins

Never widen the controller RBAC to clear a queue. A stuck queue is a capacity
or configuration problem, not a permissions problem.
