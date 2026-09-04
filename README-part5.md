# DevOps on AWS - Final Project: Observability

This part adds a monitoring and observability layer to the CI/CD system built
in Part 4. Prometheus and Grafana run inside the same cluster, the application
exposes its own metrics, and the CD pipeline now refuses to call a deployment
successful until the monitoring data says the release is healthy.

Parts 1 to 3 are documented in `README.md`. Part 4 is documented in
`README-part4.md`.

---

## Table of contents

1. [What was added](#1-what-was-added)
2. [Repository layout](#2-repository-layout)
3. [Installing the observability layer](#3-installing-the-observability-layer)
4. [Application instrumentation](#4-application-instrumentation)
5. [What is monitored](#5-what-is-monitored)
6. [Dashboards](#6-dashboards)
7. [SLI, SLO and alerts](#7-sli-slo-and-alerts)
8. [Pipeline changes](#8-pipeline-changes)
9. [Failure exercises](#9-failure-exercises)
10. [Security and operations](#10-security-and-operations)
11. [Evidence](#11-evidence)
12. [Trade-offs and known gaps](#12-trade-offs-and-known-gaps)

---

## 1. What was added

| Component | Summary |
|---|---|
| Prometheus | Operator-managed instance, own PVC, 7 day retention, explicit selector strategy |
| Grafana | Datasources and dashboards provisioned from files, no manual import |
| Alertmanager | Own PVC, grouped routes, severity-based inhibition |
| Application metrics | Counters, a histogram, a gauge, two business metrics and build identity |
| Scrape configuration | ServiceMonitors for the application and for Jenkins |
| Alert rules | Six alerts across application, platform, delivery and the monitoring system itself |
| Recording rules | Four SLI expressions shared by the alerts and the dashboards |
| Dashboards | Three, defined as JSON in Git |
| Runbooks | One per alert |
| CI | Validates every observability file before anything is built |
| CD | A post-deploy monitoring gate that queries Prometheus |

Everything is reproducible from files in this repository.

---

## 2. Repository layout

```
observability/
├── helm/
│   └── values.yaml              kube-prometheus-stack configuration
├── monitors/
│   ├── app-servicemonitor.yaml  scrape config for the backend
│   └── jenkins-servicemonitor.yaml
├── rules/
│   ├── application-rules.yaml   SLI recording rules and two app alerts
│   └── platform-rules.yaml      Kubernetes, Jenkins and monitoring alerts
├── dashboards/
│   ├── application-overview.json
│   ├── kubernetes-cluster.json
│   └── jenkins-delivery.json
├── runbooks/
│   ├── HighErrorRate.md
│   ├── HighLatencyP95.md
│   ├── ReplicasMismatch.md
│   ├── PodCrashLooping.md
│   ├── JenkinsQueueStuck.md
│   └── PrometheusTargetDown.md
└── networkpolicy.yaml           scrape paths, nothing wider

scripts/
├── 08-load-dashboards.sh        turns the JSON files into ConfigMaps
├── 09-install-observability.sh  installs the whole layer
├── monitoring-gate.sh           the post-deploy health check
└── validate-observability.py    the CI validation
```

---

## 3. Installing the observability layer

Assuming the cluster and Jenkins are already running as described in
`README-part4.md`:

```bash
./scripts/09-install-observability.sh
```

This installs the stack, waits for Prometheus, applies the ServiceMonitors,
the alert rules and the network policies, loads the three dashboards, and
prints the Grafana password.

### Reaching the interfaces

```bash
kubectl port-forward -n observability svc/monitoring-grafana 3000:80
kubectl port-forward -n observability svc/monitoring-prometheus 9090:9090
```

Neither is exposed outside the cluster. There is no Ingress for either, so a
port-forward is the only route in.

### Verifying

```bash
kubectl get pods -n observability
kubectl get servicemonitor -n observability
kubectl get prometheusrule -n observability
kubectl get configmap -n observability -l grafana_dashboard=1
```

A quick end-to-end check that the whole chain works:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=app_info'
```

The response carries the version, the git sha and the build number of the
running pods.

### Selector strategy

The chart defaults to collecting only from objects it created itself. That
would silently ignore every ServiceMonitor and PrometheusRule in this
repository, so the values file sets:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
ruleSelectorNilUsesHelmValues: false
probeSelectorNilUsesHelmValues: false
```

Prometheus now picks up any ServiceMonitor or PrometheusRule labelled
`release: monitoring`, which is what our files carry.

### Retention and storage

| Setting | Value | Reason |
|---|---|---|
| `retention` | 7d | Long enough to compare releases across a week |
| `retentionSize` | 4GB | A hard ceiling, so the volume cannot fill |
| Prometheus PVC | 5Gi | Leaves headroom above the size cap |
| Grafana PVC | 2Gi | Dashboards come from Git; this holds state only |
| Alertmanager PVC | 1Gi | Silences and notification state |

The local cluster has under 8GB of memory in total, so Prometheus is capped at
1.5GB and every other component is bounded as well. On a larger cluster these
numbers should go up before retention does.

### Recovery

Deleting the Prometheus pod loses nothing: the PVC survives and the instance
reattaches on restart. Deleting the PVC loses the stored history, which cannot
be recovered, but everything else comes back from Git:

```bash
./scripts/09-install-observability.sh
```

Dashboards, alerts and scrape configuration are files, so a rebuilt cluster
reaches the same state without anyone opening the Grafana UI.

---

## 4. Application instrumentation

### The metrics

| Metric | Type | Question it answers |
|---|---|---|
| `http_requests_total` | Counter | How much traffic, and how much of it fails |
| `http_request_duration_seconds` | Histogram | What the latency distribution looks like |
| `http_requests_in_flight` | Gauge | How many requests are being handled right now |
| `users_registered_total` | Counter | Is the service doing the work it exists to do |
| `files_uploaded_total` | Counter | The same, for the upload path |
| `dependency_failures_total` | Counter | Is the fault ours or a dependency's |
| `app_info` | Info | Which version is running |

### The business metric

`users_registered_total` is the metric that separates a service that is up from
a service that is working. A backend answering health checks while every
registration fails looks healthy on availability alone. The rate of successful
registrations does not.

### Build identity

The CI pipeline injects the build identity at image build time:

```groovy
--opt build-arg:APP_VERSION=${IMAGE_TAG}
--opt build-arg:GIT_SHA=${GIT_SHA}
--opt build-arg:RELEASE=${BUILD_NUMBER}
```

which the application reads into `app_info`:

```
app_info{git_sha="2aa93c9f44ee",release="3",version="2aa93c9f44ee"} 1.0
```

This is what closes the loop the assignment asks for: from one commit you can
reach the image tag, the running pod, and the dashboard panel showing which
version is serving.

### Cardinality

Labels are deliberately bounded: `endpoint` comes from a fixed set of Flask
route names, `method` from the HTTP verbs, `status` from response codes. No
user id, request id or raw URL is ever used as a label. Unbounded label values
are the usual way a Prometheus instance is brought down, and the limit is
easier to keep from the start than to retrofit.

### A separate endpoint

`/metrics` is separate from `/`, which the readiness and liveness probes call.
Mixing them would mean a scraping problem could get healthy pods killed, and a
probe change could break monitoring.

The health check also does not touch the database on purpose. If it did, a
brief database outage would fail the liveness probe on every replica at once
and Kubernetes would restart all of them, turning a recoverable dependency
problem into an outage. One of the unit tests asserts this, so the property
cannot be removed accidentally.

---

## 5. What is monitored

| Target | Collected by | Answers |
|---|---|---|
| Application | ServiceMonitor on the backend Service | Did the new release hurt users |
| Kubernetes | kube-state-metrics, node-exporter, kubelet | Is the fault the app or the platform |
| Jenkins | Prometheus plugin, scraped at `/prometheus/` | Is the delivery chain healthy |
| Prometheus itself | `up` on the targets above | Can the other answers be trusted |

The last row matters more than it looks. If a scrape target is down, every
alert about that component goes quiet. Absence of alerts is not evidence of
health, which is why `PrometheusTargetDown` exists.

### The Jenkins scrape path

The endpoint is `/prometheus/` with the trailing slash. Without it Jenkins
returns a 302 redirect and the scrape collects nothing. This cost real
debugging time and is recorded in the `PrometheusTargetDown` runbook.

---

## 6. Dashboards

Three dashboards, defined as JSON files in `observability/dashboards/` and
loaded by `scripts/08-load-dashboards.sh`, which turns each file into a
ConfigMap that the Grafana sidecar picks up.

Nothing is imported by hand. A dashboard edited in the UI is not a deliverable
and would be overwritten on the next reload.

### Application Overview

Traffic, error ratio, p50 p95 and p99 latency, availability against the SLO,
the running version, CPU and memory per pod, the business metrics, and
dependency failures broken down by dependency. Filterable by service, pod and
release.

The dependency panel is what turns this from a status board into a diagnostic
one: when the error ratio rises, that panel says immediately whether the fault
is in the application or in something it depends on.

### Kubernetes / Cluster

Node readiness, running and pending pods, restarts, desired versus available
replicas, node CPU and memory, CPU throttling, and persistent volume usage.

Throttling is included because it is the usual explanation for latency that
rises without any error appearing.

### Jenkins & Delivery

Queue length, blocked and pending builds, executors and agents, build results
and duration, controller JVM memory, the scrape health of every monitored
target, and the version currently deployed.

That last panel is deliberate: it puts the delivery view and the running
release on the same screen, so "did my build actually reach production" is one
glance rather than a cross-reference.

---

## 7. SLI, SLO and alerts

### The indicators

Four recording rules, evaluated every 30 seconds:

| Rule | Definition |
|---|---|
| `app:request_rate5m` | Requests per second over 5 minutes |
| `app:error_rate5m` | 5xx responses as a fraction of all responses |
| `app:availability5m` | `1 - app:error_rate5m` |
| `app:latency_p95_5m` | 95th percentile request duration |

The error ratio uses `clamp_min` on the denominator. Without it, a period with
no traffic divides by zero and the alert fires every time the service is quiet.

Recording rules mean the alert and the dashboard panel use the same definition
rather than two expressions that drift apart.

### The objectives

| SLI | SLO | Enforced by |
|---|---|---|
| Availability | 99% of requests succeed | `HighErrorRate` |
| Latency | 95% of requests under 1 second | `HighLatencyP95` |

Both thresholds also gate deployments, in `scripts/monitoring-gate.sh`.

### The alerts

| Alert | Domain | Condition | Severity |
|---|---|---|---|
| `HighErrorRate` | Application | 5xx ratio above 5% for 5m | critical |
| `HighLatencyP95` | Application | p95 above 1s for 10m | warning |
| `ReplicasMismatch` | Kubernetes | Available below desired for 10m | warning |
| `PodCrashLooping` | Kubernetes | More than 3 restarts in 15m | critical |
| `JenkinsQueueStuck` | Jenkins | Queue above 3 for 10m | warning |
| `PrometheusTargetDown` | Monitoring | A target unreachable for 5m | critical |

Each carries `severity`, `summary`, `description` and a `runbook_url` pointing
at a file in `observability/runbooks/`.

### Why the `for` clause matters

Every alert waits before firing. Failure exercise 1 shows exactly what that
buys, in the recorded output:

```
round 2  | ratio 0.11 | HighErrorRate: inactive
round 3  | ratio 0.37 | HighErrorRate: pending
round 10 | ratio 0.48 | HighErrorRate: pending
round 11 | ratio 0.49 | HighErrorRate: firing
```

The condition was true from round 3 but the alert only fired at round 11. A
brief spike would have passed through `pending` and resolved without ever
waking anyone.

---

## 8. Pipeline changes

### CI validates, it does not deploy

A `Validate Observability` stage runs `scripts/validate-observability.py`,
which parses every ServiceMonitor and PrometheusRule and checks that each
dashboard has a title and panels. A malformed file fails the build before
anything is built or pushed.

The CI pipeline does not apply any of these files. Deploying monitoring
configuration is not a build step.

### CD gates on the monitoring data

After the rollout and the smoke test, `scripts/monitoring-gate.sh` asks
Prometheus three questions:

| Check | Threshold | On failure |
|---|---|---|
| Are all scrape targets up | zero down | Fail: the release cannot be verified |
| Error ratio | below 5% | Fail |
| p95 latency | below 1 second | Fail |

A successful run looks like:

```
all scrape targets are up
5xx ratio over 5m: no data yet
p95 latency over 5m: 0.004750000000000001
monitoring gate passed: the deployed release is serving traffic within objectives
```

If the gate fails, the pipeline fails, and the existing failure block prints
pod status, recent events, the Helm history and the exact rollback command.

The point is the distinction the assignment draws: a pod reporting `Running` is
not the same as a release serving traffic correctly. The gate is what turns
"it deployed" into "it works".

If Prometheus itself is unreachable the gate fails rather than passing. An
unverifiable release is not a healthy one.

---

## 9. Failure exercises

Four exercises were run against the live system. Full output is in `evidence/`.

### 1. Controlled 5xx

Postgres was scaled to zero and sustained traffic was sent to an endpoint that
needs it.

An earlier attempt sent malformed request bodies, which produced 400s rather
than 500s and did not move the error ratio at all. Breaking the dependency
produces genuine server errors, which is what the SLI measures.

**Result:** the ratio rose to 0.49, the alert moved `inactive` to `pending` to
`firing` across eleven rounds, and both returned to normal after recovery. The
full progression is in `evidence/26`.

### 2. Pod deletion

A backend pod was deleted while the service was being polled.

**Result:** twelve consecutive requests returned 200. The deployment controller
created a replacement and available replicas returned to 2 without any human
action, because the second replica kept serving throughout.

### 3. Jenkins agent starvation

Builds were queued while agents could not start.

**Result:** the queue metric rose and the alert progressed toward firing. No
permissions were changed, in line with the runbook, which states that a stuck
queue is a capacity or configuration problem and must never be resolved by
widening the controller RBAC.

### 4. Failed release

The CD pipeline was run with `IMAGE_TAG=does-not-exist-9999`.

**Result:** the pipeline stopped at input validation. `helm history` still
showed a single revision, the running pods were untouched, and the service kept
answering. Nothing was deployed, so nothing needed rolling back.

This gate had already proven itself unplanned: a CI run once failed to push
because its registry token had expired, and the later CD run for that tag
stopped at validation rather than attempting a deployment that could not have
worked.

---

## 10. Security and operations

### Exposure

Neither Prometheus nor Grafana has an Ingress. Both are ClusterIP services
reachable only through `kubectl port-forward`. There is no public endpoint to
protect, which is the simplest form of protection available here.

If either were exposed externally, authentication and HTTPS would be required
first. That is noted rather than done, because on a local cluster there is no
DNS name to obtain a certificate for.

### Permissions

The monitoring components hold no `cluster-admin` binding. Verified in
`evidence/30`:

```
kubectl auth can-i delete pods --as=system:serviceaccount:observability:monitoring-prometheus -A
no
```

Prometheus needs to read pods, services and endpoints across namespaces to
discover targets. It has no write access anywhere.

### Network

Two NetworkPolicies allow the scrape path and nothing wider:

| Namespace | Allows | Port |
|---|---|---|
| `devops-app` | Ingress from the `observability` namespace | 5000 |
| `jenkins` | Ingress from the `observability` namespace | 8080 |

The application namespace already runs default-deny in both directions from
Part 3, so these are additive allowances on top of a closed baseline.

### Metrics content

No metric or label carries a secret or personal data. Labels are endpoint
names, HTTP methods, status codes, pod names and version strings. The Jenkins
metrics endpoint is unauthenticated, which is a deliberate and bounded choice:
it is one path, reachable only inside the cluster, further restricted by the
NetworkPolicy above, and it exposes counters and queue depths rather than
build content or credentials.

---

## 11. Evidence

| File | Shows |
|---|---|
| `22-monitoring-stack-and-first-target.txt` | The stack running and the first target scraped |
| `23-dashboards-from-code.txt` | Dashboards provisioned from files, with the sidecar log |
| `24-cd-with-monitoring-gate.txt` | A CD run passing the monitoring gate |
| `25-ci-with-observability-validation.txt` | A CI run validating the observability files |
| `26-failure-exercise-5xx.txt` | Sustained errors, the alert firing, recovery |
| `27-failure-exercise-pod-deletion.txt` | Availability maintained through a pod deletion |
| `28-failure-exercise-jenkins-queue.txt` | Queue metrics under agent starvation |
| `29-failure-exercise-failed-release.txt` | A refused release leaving the environment untouched |
| `30-monitoring-security.txt` | RBAC limits and network policies |
| `31-end-to-end-observability.txt` | Version, targets, SLIs, alerts and dashboards in one view |

---

## 12. Trade-offs and known gaps

1. **The frontend is not instrumented.** The backend and the worker both
   expose Prometheus metrics and each has its own monitor: a ServiceMonitor for
   the backend and a PodMonitor for the worker, which has no Service. The
   frontend is nginx, whose built-in status endpoint does not speak the
   Prometheus format, so covering it properly means adding an exporter sidecar
   to translate. It remains covered by the Kubernetes metrics: pod health,
   restarts, CPU and memory are all visible on the cluster dashboard.

2. **Alertmanager has no real receiver.** It groups, inhibits and routes by
   severity, but the receivers are empty rather than pointing at a chat or
   paging integration, because any real receiver needs a webhook URL that would
   be a secret. Alerts are observed through the Prometheus and Alertmanager
   interfaces.

3. **Resource limits are tuned for a laptop.** Prometheus is capped at 1.5GB
   and retention at 7 days on a cluster with under 8GB total. These are the
   first numbers to raise on real hardware.

4. **No trace correlation.** Metrics answer what and when; they do not follow a
   single request through the services. Distributed tracing would close that
   gap and is the natural next addition.

5. **The scrape path for Jenkins is unauthenticated.** Discussed in section 10.
   The alternative is scraping with credentials from a Secret, which is
   stricter and would be the right choice if the endpoint were reachable from
   outside the cluster.

6. **NetworkPolicies are defined but not enforced.** The local cluster's
   default CNI accepts them without applying them. They are correct and would
   take effect on a cluster with a policy-capable network plugin. Carried over
   from Part 3.

7. **Dependency failures are not always attributed.** During failure exercise 1
   the errors came from connection setup, which happens before the code path
   that increments `dependency_failures_total`. The counter caught nothing even
   though the database was the cause. Moving the counter into the connection
   helper would fix this, and the exercise is what surfaced it.
