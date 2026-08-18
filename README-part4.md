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
16. [Manual steps performed](#16-manual-steps-performed)

---

## 1. What was built

| Component | Summary |
|---|---|
| Cluster | Local multi-node kind cluster, one control plane and two workers |
| Jenkins | Installed with the official Helm chart, pinned version, plugins pinned |
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

1. **The webhook depends on a temporary public tunnel.** GitHub cannot reach a
   kind cluster on a laptop directly, so an ngrok tunnel exposes Jenkins for the
   duration of a session. The webhook itself works end to end: a push to main
   triggers CI, which triggers CD, with no manual step. The tunnel URL changes
   each time it restarts and the GitHub webhook has to be updated to match. A
   permanently reachable Jenkins, which a real installation would have, removes
   this dependency entirely.

2. **Job DSL script security is disabled.** `useScriptSecurity: false` is set in
   JCasC. Without it, the seed job stops on first run and requires manual
   approval through the UI, which would break the "no hidden manual
   configuration" requirement. This is acceptable because the DSL comes from a
   repository under our control, but it is a real reduction in defence in depth
   and would need a different approach where the repository is not trusted.

3. **Registry verification in CD is best effort.** The stage tries `crane` and
   then `skopeo`, and if neither is present it says so and relies on the deploy
   itself failing. An earlier version silently reported success even when the
   check failed, which was worse than not checking; it was replaced. The
   validations that matter, that the tag is present and is not `latest`, are
   enforced unconditionally.

4. **Jenkins images were not scanned.** The assignment asks for the controller
   and agent images to be scanned. Trivy was run against the application images
   in Part 3 but not against the Jenkins images here. Jenkins itself reports
   several CVEs in its core and plugins in the UI, which are recorded but not
   remediated.

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

7. **Carried over from Part 3:** metrics-server is not installed, so the HPA
   reports `<unknown>`; NetworkPolicies are defined but not enforced by kind's
   default CNI; the in-cluster PostgreSQL replaces the private RDS instance,
   which is unreachable from a local cluster.

---

## 16. Manual steps performed

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
