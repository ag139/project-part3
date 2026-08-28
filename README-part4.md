# DevOps on AWS - Part 4: Jenkins CI/CD on Kubernetes

This part adds a Jenkins-based CI/CD system to the rolling project. Jenkins runs
inside the Kubernetes cluster, provisions a fresh agent pod for every build, and
drives two separate pipelines: one that builds and publishes images, and one that
deploys them.

Parts 1 to 3 are documented in the main `README.md` at the repository root.

---

## Table of contents

1. [What was built](#1-what-was-built)
2. [Repository layout](#2-repository-layout)
3. [Prerequisites](#3-prerequisites)
4. [Setting everything up from scratch](#4-setting-everything-up-from-scratch)
5. [Architecture](#5-architecture)
6. [The CI pipeline](#6-the-ci-pipeline)
7. [The CD pipeline](#7-the-cd-pipeline)
8. [Separation of duties](#8-separation-of-duties)
9. [Building images without the Docker socket](#9-building-images-without-the-docker-socket)
10. [Credentials and secrets](#10-credentials-and-secrets)
11. [Jobs as code](#11-jobs-as-code)
12. [Failure handling and rollback](#12-failure-handling-and-rollback)
13. [Evidence](#13-evidence)
14. [Security](#14-security)
15. [Trade-offs and known gaps](#15-trade-offs-and-known-gaps)
16. [Fixes applied after the review](#16-fixes-applied-after-the-review)
17. [Manual steps performed](#17-manual-steps-performed)

---

## 1. What was built

| Component | Summary |
|---|---|
| Cluster | Local multi-node kind cluster, one control plane and two workers |
| Jenkins | Official Helm chart, chart version pinned, every plugin pinned to a tested version |
| Agents | Ephemeral pods, created per build and deleted on completion |
| Identities | Three ServiceAccounts with different permissions |
| CI pipeline | Validate, lint, test, build three images, push, publish metadata |
| CD pipeline | Validate input, render manifests, deploy with Helm, verify, smoke test |
| Image builds | Rootless BuildKit, no access to the node's Docker socket |
| Jobs | Generated from Job DSL held in this repository |
| Credentials | Provided by a labelled Kubernetes Secret, not through the UI |

Everything except the initial cluster creation and the secret values is defined
in files in this repository.

---

## 2. Repository layout

Files added in this part:

```
jenkins/
├── kind-cluster.yaml           Multi-node cluster definition
├── helm/
│   └── values.yaml             Jenkins chart values: version, plugins, agents, JCasC
├── rbac/
│   ├── serviceaccounts.yaml    jenkins namespace and three ServiceAccounts
│   ├── roles.yaml              Controller Role and the deployer Role in devops-app
│   └── dockerhub-secret.example.yaml   Shape of the registry credential
└── jobs/
    └── seed.groovy             Job DSL that creates both pipeline jobs

ci-Jenkinsfile                  CI pipeline definition
cd-Jenkinsfile                  CD pipeline definition

scripts/
├── 01-setup-cluster.sh         Cluster and ingress controller
├── 02-install-jenkins.sh       RBAC, credentials, Jenkins
├── 03-deploy-application.sh    First deployment, outside the pipeline
└── 04-collect-evidence.sh      Collects the command outputs used as evidence

architecture/
├── jenkins-architecture.svg    Controller, agents, identities, registry
└── cicd-flow.svg               Commit to deployment

evidence/                       Captured outputs, see section 13
```

---

## 3. Prerequisites

```bash
docker --version
kubectl version --client
kind version
helm version
```

A Docker Hub account with an access token that has `Read & Write` permission.

**On WSL**, the default inotify limits are too low for a three-node cluster and
the control plane will fail to start. Raise them before creating the cluster:

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w fs.inotify.max_user_watches=524288
```

To make this permanent:

```bash
echo -e "fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=524288" \
  | sudo tee -a /etc/sysctl.conf
```

Port 80 must be free. If a local web server is running, stop it first, otherwise
the cluster cannot publish the ingress ports.

---

## 4. Setting everything up from scratch

The scripts below reproduce the whole environment. They were used to rebuild it
from nothing during development, which is how the gaps in these instructions
were found.

### Step 1: cluster and ingress controller

```bash
./scripts/01-setup-cluster.sh
```

Creates the three-node cluster, waits for every node to become ready, and
installs ingress-nginx with Helm, pinned to the control plane node.

### Step 2: Jenkins

```bash
export DOCKERHUB_USER=<your docker hub username>
export DOCKERHUB_TOKEN=<your docker hub access token>

./scripts/02-install-jenkins.sh
```

Creates the namespaces, the three ServiceAccounts and their Roles, stores the
registry credential as a labelled Kubernetes Secret, and installs Jenkins.

The script prints the generated admin password at the end.

### Step 3: open the UI and create the jobs

```bash
kubectl port-forward -n jenkins svc/jenkins 8080:8080
```

Open `http://localhost:8080` and log in as `admin`.

A single job called `seed-job` is present. Run it once. It reads
`jenkins/jobs/seed.groovy` from this repository and creates `ci-application`
and `cd-application`.

### Step 4: first deployment

The application must exist before the CD pipeline can upgrade it. Deploy it
once with a tag that CI has already produced:

```bash
export DB_PASSWORD=<database password>
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>

./scripts/03-deploy-application.sh <image-tag>
```

Every deployment after this one goes through the CD pipeline.

### Step 5: expose Jenkins for the webhook

GitHub cannot reach a local cluster, so a public tunnel is needed for push
triggers. Any tunnelling tool works; ngrok was used here.

```bash
ngrok http 8080
```

Take the generated https URL and set it in two places:

1. **Manage Jenkins, System, Jenkins URL** - set it to the tunnel URL.
2. **The repository settings on GitHub, Webhooks, Add webhook**:

| Field | Value |
|---|---|
| Payload URL | `<tunnel-url>/github-webhook/` |
| Content type | `application/json` |
| Events | Just the push event |

The trailing slash on `/github-webhook/` is required.

GitHub sends a test delivery immediately. A green tick and a 200 response mean
the connection works.

This URL changes every time the tunnel restarts, and the webhook has to be
updated to match. See section 15.

### Step 6: run the pipelines

Pushing to `main` now starts `ci-application` automatically. On success it
triggers `cd-application` with the tag it produced.

Both jobs can also be started manually, and `cd-application` accepts an explicit
tag, which is how a redeploy of an earlier build is performed.

---

## 5. Architecture

See `architecture/jenkins-architecture.svg` and `architecture/cicd-flow.svg`.

```
                        git push
                            |
                            v
                    Jenkins controller
                  (schedules only, never builds)
                            |
              +-------------+-------------+
              v                           v
         ci-agent pod                cd-agent pod
      jnlp, buildkit, python       jnlp, kubectl, helm
       SA: jenkins-ci               SA: jenkins-cd
       no cluster access            Role in devops-app only
              |                           |
              v                           v
        container registry  ------->  devops-app namespace
        (the only handoff)            frontend, backend,
                                      worker, postgres
```

The controller runs no build steps. Each build gets a new pod, and the pod is
deleted when the build ends. Nothing persists between runs except what is pushed
to the registry.

---

## 6. The CI pipeline

Defined in `ci-Jenkinsfile`. Runs on `ci-agent`.

| Stage | What it does |
|---|---|
| Checkout | Resolves the commit hash, branch and build number |
| Validation | Checks the project structure and that no Dockerfile uses `latest` |
| Lint | Compiles the Python sources to catch syntax errors |
| Tests | Four checks, results published as JUnit XML |
| Build and Push | Builds three images with BuildKit and pushes them |
| Publish Metadata | Archives commit, build number, tag and digest per image |

### The tests

The four checks are deliberately about things that matter rather than
placeholders that always pass:

- the backend defines at least four routes
- the backend reads its configuration from environment variables
- the backend contains no hardcoded AWS key or database endpoint
- the worker writes the heartbeat file its probes depend on

The third check would have caught the hardcoded credentials that Part 2's code
contained.

### Image tagging

Every image is tagged with the short git commit hash, for example
`3d05a48ecda3`. The tag is immutable and points back to exactly one commit.
`latest` is rejected by the validation stage and never produced.

The digest of each pushed image is recorded in `image-metadata.txt`, archived as
a build artifact, so a running pod can be traced back through digest, tag,
build number and commit.

### What this pipeline does not do

It does not deploy, and it holds no credentials that would let it. Its
ServiceAccount has no Role, and no API token is mounted into its pod.

---

## 7. The CD pipeline

Defined in `cd-Jenkinsfile`. Runs on `cd-agent`. Takes a tag as a parameter and
deploys it.

| Stage | What it does |
|---|---|
| Checkout | Records who requested the deploy, which tag, which namespace |
| Input Validation | Rejects an empty tag, rejects `latest`, rejects a namespace other than the permitted one |
| Manifest Validation | `helm lint`, `helm template`, local dry run |
| Authenticate | Uses the in-cluster ServiceAccount and prints what it may and may not do |
| Deploy | `helm upgrade --install --wait` |
| Rollout | `kubectl rollout status` per deployment |
| Verify | Confirms the running images actually carry the requested tag |
| Smoke Test | Calls the application through its in-cluster Service |

### The Authenticate stage

This stage prints the result of two permission checks:

```
kubectl auth can-i update deployments -n devops-app   ->  yes
kubectl auth can-i delete deployments -n devops-app   ->  no
```

The second line is the point. The deployer can roll out a new version but cannot
delete the application.

### The Verify stage

Deploying successfully is not the same as running the right version. This stage
reads the images actually running in the namespace and fails if any of them does
not carry the requested tag.

### What this pipeline does not do

It does not build anything. The `cd-agent` pod has no build tooling at all, so
even a modified Jenkinsfile could not produce an image from it.

---

## 8. Separation of duties

Three ServiceAccounts, three permission sets:

| Identity | Used by | API token mounted | Permissions |
|---|---|---|---|
| `jenkins-controller` | The controller | Yes | Create and delete pods in `jenkins`, read secrets in `jenkins` |
| `jenkins-ci` | CI agent pods | **No** | None |
| `jenkins-cd` | CD agent pods | Yes | `jenkins-deployer` Role in `devops-app` |

### Why not one shared identity

A single identity means that any compromise anywhere gets everything. A
vulnerable dependency in a build script would inherit deployment rights it never
needed. Splitting them means a compromised CI build cannot reach the application
namespace at all.

### What the deployer Role permits

`get`, `list`, `watch`, `create`, `update` and `patch` on the resource types the
Helm chart contains: deployments, services, configmaps, serviceaccounts,
persistentvolumeclaims, secrets, ingresses, networkpolicies,
horizontalpodautoscalers, poddisruptionbudgets, roles and rolebindings. Plus
read access to pods, replicasets and events, which `helm --wait` needs to track
progress.

**It does not permit `delete` on anything**, and it is a namespaced `Role`, not
a `ClusterRole`. The pipeline can deploy and update, but cannot remove the
application or touch any other namespace.

It also cannot create namespaces, because namespaces are cluster-scoped. The
Helm chart's namespace template was made optional and is disabled by default for
this reason. Creating a namespace is a one-time infrastructure action, not part
of a routine deployment.

---

## 9. Building images without the Docker socket

Mounting the node's Docker socket into a build agent is equivalent to giving
that agent root on the node: anything that gets code execution in the build can
start a privileged container. Part 2's Jenkinsfile did exactly this. It is not
used here.

The CI agent instead runs a **rootless BuildKit** side container:

```yaml
sideContainerName: buildkit
image:
  repository: moby/buildkit
  tag: v0.18.2-rootless
command: rootlesskit
args: buildkitd --oci-worker-no-process-sandbox --addr unix:///home/user/.local/share/buildkit/buildkitd.sock
privileged: false
```

The pipeline talks to it over a unix socket inside the pod:

```groovy
environment {
    BUILDKIT_HOST = 'unix:///home/user/.local/share/buildkit/buildkitd.sock'
}
```

The build runs as uid 1000, with `privileged: false`, with no host mount, and
with no access to any Docker daemon. `evidence/04-rootless-buildkit.txt` shows
the worker registering successfully under these constraints.

---

## 10. Credentials and secrets

The Docker Hub credential is stored as a Kubernetes Secret carrying a label that
the `kubernetes-credentials-provider` plugin watches:

```bash
kubectl create secret generic dockerhub-creds -n jenkins \
  --from-literal=username="$DOCKERHUB_USER" \
  --from-literal=password="$DOCKERHUB_TOKEN"

kubectl label secret dockerhub-creds -n jenkins \
  "jenkins.io/credentials-type=usernamePassword"
```

Jenkins picks it up automatically and exposes it as a credential with the ID
`dockerhub-creds`. Nothing is configured through the UI, and no real value is
committed. `jenkins/rbac/dockerhub-secret.example.yaml` documents the shape.

In the pipeline it is consumed through `withCredentials`, which masks it in the
build log:

```
Masking supported pattern matches of $REG_PASS
```

The registry auth file written for BuildKit is removed in the `post` block
whether the build succeeded or failed.

---

## 11. Jobs as code

`jenkins/jobs/seed.groovy` defines both pipeline jobs: their descriptions, log
rotation, the `disableConcurrentBuilds` property, the CD parameters, and where
each one reads its Jenkinsfile from.

A `seed-job` is created by JCasC when Jenkins starts. Running it once creates
both pipelines. Re-running it after a change to `seed.groovy` updates them.

Neither `ci-application` nor `cd-application` was configured through the Jenkins
UI, and neither would survive being configured that way, since the seed job
would overwrite it.

### CI to CD handoff

The CI pipeline triggers CD on success and passes the tag it produced:

```groovy
build job: 'cd-application',
      wait: false,
      parameters: [
          string(name: 'IMAGE_TAG',        value: env.IMAGE_TAG),
          string(name: 'TARGET_NAMESPACE', value: 'devops-app'),
          string(name: 'CI_BUILD_NUMBER',  value: env.BUILD_NUMBER)
      ]
```

CD can also be run on its own with an explicit tag, which is how a rollback to
an earlier build is performed.

---

## 12. Failure handling and rollback

A deliberate failure was run to confirm that a bad deployment does not damage a
working environment. The CD pipeline was given `IMAGE_TAG=does-not-exist-0000`.

**What happened:**

The pipeline failed. The new pods entered `ImagePullBackOff`. The pods running
the previous tag stayed `1/1 Running` throughout and kept serving traffic,
because a rolling update does not remove healthy pods for a replacement that
never becomes ready.

Helm recorded the attempt without replacing the good release:

```
3   deployed     Upgrade complete
4   failed       Upgrade "devops-app" failed
```

**Rollback:**

```bash
helm rollback devops-app -n devops-app
```

After the rollback, only the previous tag was running and Helm recorded
revision 5 as `Rollback to 3`.

The failure output is in `evidence/11-cd-failure-handling.txt`, and the
before-and-after state including the rollback is in
`evidence/10-failed-deploy-no-damage.txt`.

On failure the pipeline also prints pod status, recent namespace events, the
Helm history, and the exact rollback command to run.

---

## 13. Evidence

| File | Shows |
|---|---|
| `00-cluster-state.txt` | Full cluster, Jenkins, RBAC and application state |
| `01-multinode-distribution.txt` | Pods spread across the worker nodes |
| `02-jenkins-installed.txt` | Jenkins pod, service, PVC and RBAC |
| `03-ephemeral-agent.txt` | An agent pod created, run as uid 1000 with no token, then deleted |
| `04-rootless-buildkit.txt` | BuildKit worker available without privileges |
| `05-ci-success.txt` | A full CI run |
| `06-image-metadata.txt` | Commit, tag and digest per image |
| `07-ci-pipeline-success.txt` | CI run that triggered CD |
| `08-cd-pipeline-success.txt` | A full CD run including the smoke test |
| `09-deployed-state.txt` | The cluster running the tag CI produced |
| `10-failed-deploy-no-damage.txt` | A failed deploy leaves the environment intact, then rollback |
| `11-cd-failure-handling.txt` | The failure output of the CD pipeline |
| `12-webhook-triggered-build.txt` | A build started by a GitHub push, which then triggered CD |
| `13-jobs-generated-from-code.txt` | Seed job output and API listing, proving both jobs come from code |
| `14-ci-failure-no-promotion.txt` | A failing CI run: no image pushed, CD never scheduled |
| `15-jenkins-image-scans.txt` | Trivy results for the controller, agent and side container images |
| `16-ci-with-image-scanning.txt` | A CI run including the scan stage and its policy check |
| `17-cd-fails-closed-on-missing-image.txt` | CD refusing a tag that was never published |
| `19-ci-with-linting-and-tests.txt` | A CI run with ruff, bandit and the unit tests |
| `20-cd-with-digest-verification.txt` | A CD run resolving digests before deploying |
| `21-pinning-and-hardening.txt` | Pinned versions, security contexts, policies and the webhook ingress |

Regenerate the cluster state at any time with:

```bash
./scripts/04-collect-evidence.sh
```

---

## 14. Security

### Controller and agents

The controller schedules work and never runs build steps. Its Role is limited to
the `jenkins` namespace and covers pod lifecycle, pod logs and exec, events, and
read access to secrets, which the credentials provider requires.

Agent pods run with:

```yaml
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
privileged: false
```

The CI agent additionally has no ServiceAccount token mounted at all.

### Images

The Jenkins controller image is pinned to `2.504.3-lts-jdk17`. Every plugin is
pinned to the exact version that was verified working, listed in
`jenkins/helm/values.yaml`. The BuildKit and Python side containers are pinned
to specific tags. No image uses `latest`.

### Secrets

No credential is stored in this repository, in a Jenkinsfile, or in the Jenkins
UI. The registry credential lives in a Kubernetes Secret; the pipeline reads it
through `withCredentials`, which masks it in logs. The auth file it writes is
deleted in the `post` block.

### Network posture

Only the frontend is reachable from outside the application namespace, through
the Ingress. Jenkins itself is a `ClusterIP` service reached with
`port-forward`; it is not exposed outside the cluster.

### What is not covered

Listed honestly in the next section.

---

## 15. Trade-offs and known gaps

This section was rewritten after the review. Items 1, 3 and 4 of the previous
version have been resolved and are described in section 17.

1. **The webhook depends on a temporary public tunnel.** GitHub cannot reach a
   kind cluster on a laptop directly, so a tunnel is needed. The exposure has
   been narrowed: an Ingress publishes only `/github-webhook/`, so the tunnel
   no longer puts the Jenkins UI on a public URL. The UI is reachable only
   through `kubectl port-forward`. The tunnel URL still changes on restart and
   the GitHub webhook has to be updated to match. A permanently reachable
   Jenkins removes the dependency entirely.

2. **Job DSL script security is disabled.** `useScriptSecurity: false` is set in
   JCasC. Without it the seed job stops on first run and requires manual
   approval through the UI, which would break the "no hidden manual
   configuration" requirement. This is acceptable because the DSL comes from a
   repository under our control, but it is a real reduction in defence in depth
   and would need a different approach where the repository is not trusted.

3. **The controller runs without a read-only root filesystem.** Every other
   hardening control is applied: `runAsNonRoot`, a fixed uid and gid,
   `RuntimeDefault` seccomp, `allowPrivilegeEscalation: false` and all
   capabilities dropped. `readOnlyRootFilesystem` is left off because the
   Jenkins controller writes to several paths outside its data volume during
   startup and plugin loading. The assignment asks for it "where compatible",
   and it is not compatible here without mapping every write path. Agent
   containers have no such requirement and run with the same restrictions.

4. **Restricting the webhook to POST was not possible.** The Ingress was meant
   to reject any method other than POST, but this ingress-nginx installation
   disables configuration snippets by default, which is the safer posture.
   Path scoping alone still removes the UI from the public surface.

5. **Helm had to adopt resources created with kubectl.** The application was
   originally deployed with `kubectl apply -f k8s/`, so Helm refused to manage
   resources it did not create. They were annotated and labelled as Helm-managed
   once. The two deployment paths cannot share ownership of the same objects;
   Helm is the path the CD pipeline uses, and `kubectl apply` is for a
   standalone environment only.

6. **PostgreSQL is redeployed with the application.** It is part of the same
   chart, so every deploy waits for it. A database is infrastructure rather than
   something that ships with each build, and separating it would remove a
   recurring source of timeouts.

7. **Application secrets do not survive a cluster rebuild.** `db-secrets` and
   `aws-secrets` are created imperatively so their values never reach a file.
   The consequence is that a rebuilt cluster has no secrets, the pods fail with
   `CreateContainerConfigError`, and `helm --wait` rolls the release back,
   leaving an apparently empty namespace. `scripts/00-start.sh` now recreates
   them automatically. A secrets manager with an external provider would remove
   the problem rather than work around it.

8. **Carried over from Part 3:** metrics-server is not installed, so the HPA
   reports `<unknown>`; NetworkPolicies in the application namespace are defined
   but not enforced by kind's default CNI; the in-cluster PostgreSQL replaces
   the private RDS instance, which is unreachable from a local cluster.

---

## 16. Fixes applied after the review

The review listed seven priority improvements. All seven were implemented.

### 1. Mandatory image scanning in CI

A `Scan Images` stage runs after the build and before the metadata is
published. It scans all three application images with Trivy at HIGH and
CRITICAL severity, writes a table report and a JSON report per image, archives
both as build artifacts, and enforces a declared policy:

```groovy
MAX_CRITICAL = '10'
```

An image exceeding the limit fails the stage, which means nothing is promoted
and CD is never triggered. The threshold reflects what the base images actually
carry today and can be tightened; a number that fails every build would have
been theatre rather than a gate.

The Jenkins controller, the inbound agent and every side container image were
also scanned. Results are in `evidence/15-jenkins-image-scans.txt`.

### 2. Deterministic Jenkins recovery

The chart is pinned in the install script:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --version 5.9.54 \
  ...
```

Every plugin is pinned to an exact version, and both
`installLatestPlugins` and `installLatestSpecifiedPlugins` are `false`.

**The tested compatibility set:**

| Component | Version |
|---|---|
| Chart | `5.9.54` |
| Controller image | `jenkins/jenkins:2.504.3-lts-jdk17` |
| `kubernetes` | `4437.v3a_18554d3f32` |
| `workflow-aggregator` | `608.v67378e9d3db_1` |
| `git` | `5.10.1` |
| `configuration-as-code` | `2036.v0b_c2de701dcb_` |
| `job-dsl` | `3732.v9a_c49a_61a_313` |
| `credentials-binding` | `728.v902a_273b_8947` |
| `pipeline-stage-view` | `2.41` |
| `junit` | `1369.v15da_00283f06` |
| `timestamper` | `1.30` |
| `ws-cleanup` | `0.49` |
| `github` | `1.47.0` |
| `kubernetes-credentials-provider` | `1.315.v92008589c044` |

These versions were not chosen from documentation. An earlier attempt to pin
guessed versions produced plugins that failed to load, with a symptom that gave
nothing away: pipelines reported `SUCCESS` in seconds without running a single
stage, because the plugin that interprets declarative syntax was among the
failures. The versions above were read back out of a working installation and
then locked, and a clean install now starts with no failed plugins.

### 3. Fail-closed CD input validation

The CD agent has a `crane` container. The validation stage resolves a digest
for every required image and exits non-zero if any is missing:

```
ERROR: ayeletgeulayev/devops-app-backend:<tag> was not found in the registry
one or more images are missing from the registry.
refusing to deploy a tag that has not been published by CI.
```

The resolved digests are archived as `resolved-digests.txt`, so a deployment
can be traced to exact image content rather than to a mutable tag.

This gate proved itself in an unplanned way. A CI run failed to push because
its registry token had expired, and a later CD run for that tag stopped at
validation rather than attempting a deployment that could not have worked.
`evidence/17-cd-fails-closed-on-missing-image.txt` records it.

### 4. Failure evidence

A branch with a deliberate syntax error was pushed and CI was run against it.
The pipeline stopped at `Lint`; `Tests`, `Build and Push`, `Scan Images` and
`Publish Metadata` never ran, no image was pushed, and `cd-application` was
never scheduled. `evidence/14-ci-failure-no-promotion.txt` includes the console
output and a listing showing the CD job has no build for it.

`evidence/13-jobs-generated-from-code.txt` contains the seed job output creating
both pipelines and the API response listing them, as proof that neither was
configured through the UI.

### 5. Pod hardening and exposure

Controller and agent pods declare:

```yaml
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
fsGroup: 1000
seccompProfile:
  type: RuntimeDefault
```

and at container level:

```yaml
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
```

`readOnlyRootFilesystem` is discussed in section 15.

Three NetworkPolicies apply to the `jenkins` namespace: default-deny for both
directions, an allow rule for the controller that permits inbound traffic only
from within the namespace and from the ingress-nginx namespace, and an
egress-only rule for agents.

The webhook is exposed through an Ingress scoped to `/github-webhook/` with
`pathType: Exact`, so a tunnel pointed at the ingress controller publishes only
that path and not the Jenkins UI.

### 6. Lifecycle scripts and documentation

| Script | Purpose |
|---|---|
| `00-start.sh` | Restores the environment after a host restart |
| `01-setup-cluster.sh` | Creates the cluster and the ingress controller |
| `02-install-jenkins.sh` | RBAC, credentials, Jenkins at pinned versions |
| `03-deploy-application.sh` | First deployment, outside the pipeline |
| `04-collect-evidence.sh` | Captures cluster state |
| `05-verify.sh` | Health and permission checks |
| `06-update.sh` | Applies configuration changes |
| `07-uninstall.sh` | Removes the platform, optionally the cluster |

All are idempotent and safe to re-run.

`05-verify.sh` checks more than liveness. It asserts that the deployer **can**
update deployments and **cannot** delete them, and that the CI identity cannot
reach the application namespace at all. A permission that has quietly widened
shows up as a failed check.

`00-start.sh` encodes two things learned the hard way: kind's control plane
must claim its address before the workers start, or it fails with
`have an old IPv4 address but no current IPv4 address`; and the application
secrets have to be recreated after a rebuild.

`jenkins/rbac/dockerhub-secret.example.yaml` documents the credential shape and
the rotation procedure: create a new token, re-run the two commands, revoke the
old one. The credentials provider watches the secret, so no restart is needed.

### 7. Real linting and executable tests

`python -m py_compile` was replaced with `ruff` (style, correctness, security
and import rules) and `bandit` (Python security analysis). A medium or high
finding from bandit fails the stage, and both reports are archived.

Two findings are suppressed with an explanation in the source rather than
silently: binding to `0.0.0.0`, without which nginx could not reach the backend
from another pod, and the fixed `/tmp/healthy` path, which is exactly what the
worker's probes check and the only writable mount on a read-only filesystem.

Fourteen unit tests run under pytest with results published as JUnit XML:

| Area | What is covered |
|---|---|
| Routes | All four endpoints, status codes, response shape |
| Design | That `/` does not query the database, so an outage cannot fail the liveness probe and kill healthy pods |
| Security | That a name containing SQL is parameterised, not concatenated |
| Configuration | That required variables come from the environment and a missing one fails at import |
| Failure cases | That storage and notification failures surface as 500 rather than a false success |
| Source | That no AWS key or database endpoint is hardcoded |

The last one would have caught the credentials that Part 2's code contained.

---

## 17. Manual steps performed

1. **Raising the inotify limits.** Required on WSL before the cluster can start.
   Included in `scripts/01-setup-cluster.sh`.
2. **Creating the cluster.** `kind create cluster`, wrapped in the same script.
3. **Providing the registry credential.** Passed as environment variables to
   `scripts/02-install-jenkins.sh` so the value never reaches a file.
4. **Running the seed job once** to create both pipelines.
5. **The first application deployment**, through
   `scripts/03-deploy-application.sh`. Every deployment after it goes through CD.
6. **Annotating pre-existing resources as Helm-managed**, a one-time migration
   described in section 15.

Everything else is created by the scripts, the Helm values, the RBAC manifests,
the Job DSL, and the two Jenkinsfiles.
