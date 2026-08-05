# DevOps on AWS - Part 3: Running the Application on Kubernetes

This is the third stage of the rolling project.

- **Part 1** - the application was deployed manually on AWS: three services on
  three separate EC2 instances, plus RDS (PostgreSQL), S3, SNS and nginx.
- **Part 2** - the same environment was automated: all infrastructure created
  with Terraform, all server configuration and application deployment done with
  Ansible.
- **Part 3 (this part)** - the three application services now run as containers
  inside a Kubernetes cluster instead of on individual EC2 instances. S3 and SNS
  remain real, external AWS services that the application calls from inside the
  cluster.

---

## Table of contents

1. [Architecture](#architecture)
2. [What runs inside the cluster vs outside](#what-runs-inside-the-cluster-vs-outside)
3. [Repository layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Building the images](#building-the-images)
6. [Loading images into the cluster](#loading-images-into-the-cluster)
7. [Creating the cluster and add-ons](#creating-the-cluster-and-add-ons)
8. [Creating the Namespace](#creating-the-namespace)
9. [Creating the Secret](#creating-the-secret)
10. [Deploying the application](#deploying-the-application)
11. [Verifying the system works](#verifying-the-system-works)
12. [Deleting the environment](#deleting-the-environment)
13. [Database: why in-cluster PostgreSQL instead of the existing RDS](#database-why-in-cluster-postgresql-instead-of-the-existing-rds)
14. [Security](#security)
15. [Trade-offs and compromises](#trade-offs-and-compromises)
16. [Manual steps performed](#manual-steps-performed)

---

## Architecture

```
                            User (HTTP)
                                 │
                                 ▼
                    Ingress (ingress-nginx controller)
                                 │
                                 ▼
                   frontend Service (ClusterIP, port 80)
                                 │
                                 ▼
                   frontend Pods - nginx, 2 replicas
                        (reverse proxy, port 8080)
                                 │
                                 ▼
                   backend Service (ClusterIP, port 5000)
                                 │
                                 ▼
                   backend Pods - Flask API, 2 replicas
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
      postgres Service      S3 bucket           SNS topic
       (in-cluster)         (real AWS)          (real AWS)
              │
              ▼
      postgres Pod + PVC

      worker Pod - background loop, 1 replica
      (no Service, no Ingress - outbound only)
```

The architecture diagram is in `architecture/k8s-architecture.svg`.

### Application services

| Service    | Image base          | Replicas | Exposed externally | Purpose |
|------------|---------------------|----------|--------------------|---------|
| `frontend` | `nginx:1.27-alpine` | 2        | Yes, via Ingress   | Reverse proxy - the only public entry point |
| `backend`  | `python:3.12-slim`  | 2 (HPA 2-6) | No              | Flask API: `/`, `/users`, `/add_user`, `/upload` |
| `worker`   | `python:3.12-slim`  | 1        | No                 | Background loop (carried over from Part 2) |
| `postgres` | `postgres:16`       | 1        | No                 | In-cluster database (see section 13) |

### Backend endpoints

| Endpoint     | Method | What it does |
|--------------|--------|--------------|
| `/`          | GET    | Health check - used by readiness/liveness probes |
| `/users`     | GET    | Reads all rows from the `users` table |
| `/add_user`  | POST   | Inserts a user into PostgreSQL, then publishes a message to SNS |
| `/upload`    | POST   | Uploads a file to S3, then publishes a message to SNS |

---

## What runs inside the cluster vs outside

**Inside the Kubernetes cluster:**
- `frontend` (nginx reverse proxy)
- `backend` (Flask API)
- `worker` (background service)
- `postgres` (PostgreSQL 16 - for local testing only, see section 13)

**Outside the cluster (real AWS services):**
- **S3** - bucket `ayelet-backend-bucket`, used by `/upload`
- **SNS** - topic `project-alerts`, used by `/add_user` and `/upload`
- **RDS** - the PostgreSQL instance `project-db` created by Terraform in Part 2
  still exists in AWS, but is **not** used by this local deployment. The reason
  is documented in detail in section 13.

---

## Repository layout

```
project-part3/
├── k8s/                          Plain kubectl manifests
│   ├── namespace.yaml
│   ├── serviceaccounts.yaml      One ServiceAccount per Deployment
│   ├── rbac.yaml                 Role + RoleBinding (least privilege)
│   ├── configmap.yaml            Non-sensitive configuration
│   ├── postgres.yaml             In-cluster PostgreSQL (ConfigMap, PVC, Deployment, Service)
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   ├── worker-deployment.yaml
│   ├── ingress.yaml
│   ├── networkpolicy.yaml        Default-deny + explicit allow rules
│   ├── hpa.yaml                  HorizontalPodAutoscaler
│   └── pdb.yaml                  PodDisruptionBudget
│
├── examples/
│   └── secret.example.yaml       Example only - never applied, never contains real values
│
├── helm/devops-app/              Equivalent Helm chart (bonus)
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/                Same resources, parameterized
│
├── docker/
│   ├── frontend/                 Dockerfile, nginx.conf, .dockerignore
│   ├── backend/                  Dockerfile, app.py, requirements.txt, .dockerignore
│   └── worker/                   Dockerfile, worker.py, requirements.txt, .dockerignore
│
├── architecture/
│   └── k8s-architecture.svg
│
├── screenshots/                  Command outputs proving the system works
│   ├── 01-kubectl-resources.txt  nodes, namespaces, pods, deployments, services, ingress
│   ├── 02-describe-pod.txt
│   ├── 03-pod-logs.txt
│   ├── 04-application-tests.txt  HTTP, frontend to backend, database, S3
│   └── 05-restart-resilience.txt Pod deleted and replaced with no downtime
│
└── README.md
```

Use **either** `k8s/` with `kubectl` **or** the Helm chart - both deploy the same
resources. Do not apply both at once.

**Note on `examples/secret.example.yaml`:** this file is deliberately kept
*outside* the `k8s/` directory. If it lived in `k8s/`, running
`kubectl apply -f k8s/` would overwrite the real Secret with the placeholder
values it contains. Keeping it in `examples/` satisfies the assignment
requirement to submit an example secret file while making it impossible to apply
it by accident.

---

## Prerequisites

- Docker
- `kubectl`
- `kind`
- AWS credentials (an IAM user with permission to publish to SNS and write to S3)

Verify:

```bash
docker --version
kubectl version --client
kind version
```

---

## Building the images

All three images are built from Dockerfiles written for this project. Run these
from the repository root (`project-part3/`):

```bash
docker build -t devops-app-frontend:1.0.0 docker/frontend
docker build -t devops-app-backend:1.0.0  docker/backend
docker build -t devops-app-worker:1.0.0   docker/worker
```

Image tags are pinned to `1.0.0` - `latest` is never used, so every rollout is
reproducible and `kubectl rollout undo` has a meaningful target.

---

## Loading images into the cluster

Because the cluster is local (`kind`), there is no need to push to a registry -
images are loaded directly into the cluster nodes:

```bash
kind load docker-image devops-app-frontend:1.0.0 --name devops-app
kind load docker-image devops-app-backend:1.0.0  --name devops-app
kind load docker-image devops-app-worker:1.0.0   --name devops-app
```

**If pushing to a real registry instead** (ECR or Docker Hub), the equivalent
would be:

```bash
docker tag devops-app-backend:1.0.0 <registry>/devops-app-backend:1.0.0
docker push <registry>/devops-app-backend:1.0.0
```

and then updating the `image:` field in the Deployment manifests (or
`image.registry` in `helm/devops-app/values.yaml`) to point at that registry.

---

## Creating the cluster and add-ons

```bash
kind create cluster --name devops-app
```

Install the ingress-nginx controller (required for the Ingress resource):

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Install metrics-server (required for the HorizontalPodAutoscaler to read CPU
metrics):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Note:** metrics-server was not installed in the submitted environment. The
HorizontalPodAutoscaler objects are defined and apply cleanly, but without a
metrics source they report `<unknown>` for CPU utilization and do not actually
scale. The step above is what would be needed to make them functional.

---

## Creating the Namespace

All application resources run in a dedicated namespace - never `default`:

```bash
kubectl apply -f k8s/namespace.yaml
```

---

## Creating the Secret

Secrets are **never** committed to git. The real Secret is created imperatively
from the command line, so the values only ever exist in the shell environment
and in the cluster:

```bash
kubectl create secret generic app-secrets -n devops-app \
  --from-literal=DB_USER=app \
  --from-literal=DB_PASSWORD='<database password>' \
  --from-literal=AWS_ACCESS_KEY_ID='<AWS access key id>' \
  --from-literal=AWS_SECRET_ACCESS_KEY='<AWS secret access key>'
```

- `DB_USER` / `DB_PASSWORD` - credentials for the in-cluster PostgreSQL. These
  are consumed both by PostgreSQL itself (which creates the user on first
  initialization) and by the backend/worker when connecting.
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` - real IAM user credentials,
  picked up automatically by `boto3` from the environment. Needed for S3 and SNS.

`examples/secret.example.yaml` shows the expected shape of this Secret with
placeholder values, for reviewers.

**Important:** if the PostgreSQL password is changed after the database has
already initialized, the change will not take effect - PostgreSQL only creates
its user on the very first startup with an empty data directory. To apply a new
password, the PersistentVolumeClaim must be deleted so the database initializes
from scratch:

```bash
kubectl delete deployment postgres -n devops-app
kubectl delete pvc postgres-pvc -n devops-app
kubectl apply -f k8s/
```

---

## Deploying the application

**With kubectl:**

```bash
kubectl apply -f k8s/
```

**With Helm (bonus):**

```bash
helm install devops-app ./helm/devops-app \
  --set secrets.dbUser=app \
  --set secrets.dbPassword="$DB_PASSWORD" \
  --set secrets.awsAccessKeyId="$AWS_ACCESS_KEY_ID" \
  --set secrets.awsSecretAccessKey="$AWS_SECRET_ACCESS_KEY"

# subsequent updates:
helm upgrade --install devops-app ./helm/devops-app
```

---

## Verifying the system works

### Cluster and resource state

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -n devops-app
kubectl get deployments -n devops-app
kubectl get services -n devops-app
kubectl get ingress -n devops-app
kubectl describe pod <pod-name> -n devops-app
kubectl logs <pod-name> -n devops-app
```

Expected result: six pods running - 2 × `frontend`, 2 × `backend`, 1 × `worker`,
1 × `postgres`.

### Accessing the application over HTTP

```bash
kubectl port-forward -n devops-app svc/frontend 8080:80
```

In a second terminal:

```bash
curl http://localhost:8080/
# {"message":"app is running"}
```

This single request proves the **frontend → backend** path: nginx receives it on
port 8080 and proxies it to `backend:5000` using in-cluster DNS.

Alternatively, through the Ingress: add `devops-app.local` to `/etc/hosts`
pointing at the kind node address, then `curl http://devops-app.local/`.

### Application → database

```bash
curl -X POST http://localhost:8080/add_user \
  -H "Content-Type: application/json" \
  -d '{"name":"test-user"}'
# {"status":"user added"}

curl http://localhost:8080/users
# [[1,"test-user"]]
```

### Application → S3

```bash
echo "test file content" > /tmp/testfile.txt
curl -X POST -F "file=@/tmp/testfile.txt" http://localhost:8080/upload
# {"status":"file uploaded"}

aws s3 ls s3://ayelet-backend-bucket/
```

The uploaded file also appears in the S3 console under the bucket, confirming
that a pod running inside the local cluster successfully wrote to a real AWS
service.

### Application → SNS

A successful `{"status":"user added"}` or `{"status":"file uploaded"}` response
is itself the proof that SNS worked: in `app.py`, `sns.publish()` is called
*after* the database write and *before* the response is returned, so any SNS
failure surfaces as an HTTP 500 rather than a success response. The email
subscriber on the `project-alerts` topic also receives the notification.

### Pod restart resilience

```bash
kubectl get pods -n devops-app
kubectl delete pod <backend-pod-name> -n devops-app
kubectl get pods -n devops-app
curl http://localhost:8080/
```

The Deployment immediately creates a replacement pod. Because `backend` runs two
replicas and the readiness probe keeps the new pod out of the Service until it is
actually healthy, requests continue to be served throughout - there is no
downtime.

---

## Deleting the environment

```bash
# if deployed with kubectl
kubectl delete -f k8s/
kubectl delete secret app-secrets -n devops-app

# if deployed with Helm
helm uninstall devops-app

# tear down the whole local cluster
kind delete cluster --name devops-app
```

Note that `kubectl delete -f k8s/` removes the PersistentVolumeClaim as well, so
all database data is lost. The AWS resources (S3 bucket, SNS topic, RDS instance)
are managed by the Part 2 Terraform code and are not affected - they are
destroyed with `terraform destroy` in that repository.

---

## Database: why in-cluster PostgreSQL instead of the existing RDS

This is the most significant architectural decision in this part of the project,
so it is documented in full.

### The original intention

The plan was to reuse the RDS PostgreSQL instance created by Terraform in Part 2
(`identifier = "project-db"`, `db_name = "projectdb"`), exactly as the assignment
suggests as its first recommended option. Reusing it would keep a single source
of truth for data across all three parts of the project.

### Why it turned out to be impossible with a local cluster

The Terraform code in Part 2 creates the RDS instance like this:

```hcl
resource "aws_db_instance" "postgres" {
  identifier             = "project-db"
  db_name                = "projectdb"
  db_subnet_group_name   = aws_db_subnet_group.main.name   # private subnets only
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false
  ...
}
```

Two properties make this instance unreachable from a local cluster:

1. **`publicly_accessible = false`** - AWS does not assign the instance a public
   IP address or a publicly resolvable DNS record at all. The endpoint resolves
   only to a private address inside the VPC.
2. **The DB subnet group contains only private subnets** - the instance lives in
   `private_subnet_backend` and `private_subnet_worker`, which have no route to
   the internet gateway.

The `kind` cluster runs on a local machine, entirely outside AWS. Its pods have
no presence in the VPC, so they can never reach a private RDS endpoint.

It is worth being precise about *why* this cannot be fixed by editing a Security
Group. Security Groups filter traffic that already reached the VPC; they cannot
create a network path that does not exist. With `publicly_accessible = false`,
there is no route from the public internet to the instance for a Security Group
rule to permit. Opening port 5432 to the local machine's IP address would have no
effect whatsoever.

### The options that were considered

| Option | Why it was not chosen |
|---|---|
| Set `publicly_accessible = true` and open the Security Group | Exposes a production-shaped database to the public internet for the convenience of a local test environment. This directly contradicts the network-security requirements of Parts 2 and 3, which ask for minimal Security Groups and no unnecessary open ports. |
| Deploy the cluster on EKS instead of kind | This is the technically correct solution and would let the pods reach RDS over the VPC's private network with no changes to the application. It was not chosen for this submission because of the AWS cost of running an EKS control plane and node group, and because the assignment explicitly permits `kind`/`k3d` as an alternative. |
| VPN or bastion tunnel from the local machine into the VPC | Significant additional setup and moving parts, none of which teaches anything about Kubernetes - the actual subject of this assignment. |
| **Run PostgreSQL inside the cluster** | **Chosen.** Explicitly permitted by the assignment ("for practice purposes only: PostgreSQL inside Kubernetes, provided it is explained why this is less appropriate for production"). |

### Why in-cluster PostgreSQL is not appropriate for production

The assignment asks specifically for this explanation, and it is worth stating
plainly rather than treating the in-cluster database as equivalent to RDS:

- **Storage durability.** The database's data lives in a PersistentVolumeClaim
  backed by the kind node's local disk. If the node is lost, the data is lost.
  RDS replicates storage across multiple Availability Zones.
- **No automated backups or point-in-time recovery.** RDS takes automated
  snapshots and supports restoring to any second within the retention window.
  Nothing equivalent exists here; a `kubectl delete pvc` destroys the data
  irrecoverably.
- **No high availability or automatic failover.** This is a single-replica
  Deployment. If the pod dies, the database is down until it restarts. RDS
  Multi-AZ fails over to a standby automatically.
- **A Deployment is the wrong controller for a stateful workload.** Even for
  in-cluster databases, a StatefulSet is the correct choice: it gives stable
  network identity and ordered, per-replica storage. A Deployment is used here
  only because a single replica with `strategy: Recreate` is sufficient for
  local testing, and the extra complexity would not demonstrate anything the
  assignment asks for.
- **Manual version upgrades and patching.** RDS handles minor version patching
  in a maintenance window. Here, upgrading means changing an image tag and
  hoping the on-disk data format is compatible.
- **Credentials management.** RDS integrates with AWS Secrets Manager for
  automatic rotation. The in-cluster database's password is a static Kubernetes
  Secret that never rotates.

### What would change on EKS

The application code requires no changes whatsoever to switch back to RDS -
this was a deliberate design goal. `app.py` reads every connection parameter from
environment variables, so moving to RDS means only:

1. Deleting `k8s/postgres.yaml` (the in-cluster database and its Service).
2. Changing four values in `k8s/configmap.yaml` and the Secret:
   - `DB_HOST` - from `postgres` to the RDS endpoint
   - `DB_NAME` - from `appdb` to `projectdb`
   - `DB_USER` / `DB_PASSWORD` - to the RDS master credentials
3. Ensuring the EKS node group's security group is allowed by the RDS security
   group on port 5432.

The `NetworkPolicy` already permits egress from `backend` and `worker` on port
5432, so no policy change would be needed either.

### Note on S3 and SNS

S3 and SNS are **not** affected by this problem and are used as real AWS services
throughout. Unlike RDS, they are public AWS API endpoints reachable over HTTPS
from anywhere on the internet, so a pod in a local cluster can call them normally
given valid credentials. The `/upload` endpoint writes to the real
`ayelet-backend-bucket`, and both `/add_user` and `/upload` publish to the real
`project-alerts` topic.

---

## Security

The assignment requires a dedicated security section. Each required topic is
covered below.

### Permission separation - ServiceAccounts

Each Deployment runs under its **own** ServiceAccount rather than sharing one:

| Deployment | ServiceAccount | API token mounted | RBAC permissions |
|------------|----------------|-------------------|------------------|
| `frontend` | `frontend-sa`  | No                | None |
| `backend`  | `backend-sa`   | No                | Read-only Role (see below) |
| `worker`   | `worker-sa`    | No                | None |

None of these services needs to talk to the Kubernetes API - they talk to nginx,
Flask routes, PostgreSQL and AWS APIs. Accordingly,
`automountServiceAccountToken: false` is set on all three ServiceAccounts, so a
compromised pod has no API token to steal in the first place.

**Why not one shared ServiceAccount with broad permissions:** with a single
shared account, a vulnerability anywhere - an unpatched dependency in the
backend, a misconfigured nginx - grants the attacker everything that account can
do, across all three services. Separate accounts mean a frontend compromise
cannot act as the backend, and neither can act as the worker. This is the
principle of least privilege applied at the workload identity level, and it costs
nothing to implement.

### RBAC

`k8s/rbac.yaml` defines:

- **Role** `devops-app-readonly`, namespaced to `devops-app`, granting
  `get`, `list` and `watch` on `configmaps` and `pods` only.
- **RoleBinding** `backend-readonly-binding`, binding that Role to
  `backend-sa` only.

`frontend-sa` and `worker-sa` have no RoleBinding at all - zero API permissions.

**No workload in this project is bound to `cluster-admin` or to any
cluster-scoped Role.** All RBAC is namespace-scoped.

Strictly speaking, even `backend-sa` does not currently need these permissions
(it never calls the Kubernetes API, and its token is not mounted). The Role is
included to demonstrate least-privilege RBAC as the assignment requires, scoped
as narrowly as possible rather than granted broadly "just in case".

### Secrets management

- **Where secrets are stored:** in a Kubernetes Secret named `app-secrets` in
  the `devops-app` namespace, injected into pods as environment variables via
  `envFrom.secretRef`.
- **How they are created:** imperatively with `kubectl create secret generic`
  (see the section above), so the real values never touch a file in the
  repository.
- **What is committed to git:** only `examples/secret.example.yaml`, which
  contains placeholder values and is deliberately kept outside `k8s/` so that
  `kubectl apply -f k8s/` cannot overwrite the real Secret with placeholders.
- **Which tools are used:** Kubernetes Secrets only in this submission. No
  Sealed Secrets, External Secrets Operator or AWS Secrets Manager integration.

**Limitation, stated honestly:** Kubernetes Secrets are only base64-encoded, not
encrypted, unless encryption at rest is explicitly configured on the cluster's
etcd. Anyone with `get secret` permission in the namespace can read them in
plaintext. In a production setup the natural upgrade is AWS Secrets Manager with
the External Secrets Operator, which centralizes secrets, supports rotation, and
produces an audit trail of every access.

### Network security

`k8s/networkpolicy.yaml` starts from a **default-deny** posture for both ingress
and egress across the whole namespace, then allows only what is needed:

| Component  | Who can connect to it | What it can connect to |
|------------|-----------------------|------------------------|
| `frontend` | The ingress-nginx controller namespace only | `backend` on 5000, DNS |
| `backend`  | `frontend` pods only, on port 5000 | 443 (S3/SNS), 5432 (database), DNS |
| `worker`   | **Nobody** - no ingress rule at all | 443 (S3/SNS), 5432, DNS |
| `postgres` | `backend` and `worker` on 5432 | DNS |

Who can talk to the database: only pods inside the namespace that the policy
permits - `backend` and `worker`. The database has no Ingress, no NodePort and
no LoadBalancer Service, so it is unreachable from outside the cluster entirely.

**Which components are exposed externally:** only `frontend`, and only through
the Ingress. `backend`, `worker` and `postgres` all use `ClusterIP` Services (or,
in the worker's case, no Service at all) and have no Ingress rules.

**Enforcement caveat:** kind's default CNI (kindnet) does not enforce
NetworkPolicy objects. The policies apply cleanly and are correct, but to see
them actually block traffic the cluster needs a policy-enforcing CNI such as
Calico:

```bash
cat > kind-calico.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
EOF

kind create cluster --name devops-app --config kind-calico.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

This was not done in the submitted environment - the cluster runs with kindnet,
so the NetworkPolicies are present and correct but not actively enforcing.

On EKS, NetworkPolicy is enforced by the AWS VPC CNI (recent versions) or by
Calico installed as an add-on.

### Container security

Every pod sets, at the pod level:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: <uid>
  runAsGroup: <gid>
  fsGroup: <gid>
  seccompProfile:
    type: RuntimeDefault
```

and, at the container level:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

Details:

- **Non-root:** `backend` and `worker` run as uid 1000 (a dedicated `appuser`
  created in their Dockerfiles). `frontend` runs as uid 101, nginx's built-in
  non-root user. `postgres` runs as uid 999, the postgres image's own user.
- **No privilege escalation:** `allowPrivilegeEscalation: false` prevents a
  process from gaining more privileges than its parent, blocking setuid-binary
  escalation paths.
- **Read-only root filesystem:** the only writable paths are explicit `emptyDir`
  volumes - `/tmp` for backend and worker, and `/tmp`, `/var/cache/nginx`,
  `/var/run` for nginx. Everything else in the container is immutable at runtime,
  which limits what a code-execution exploit can persist or tamper with.
- **Minimal capabilities:** all Linux capabilities are dropped. None of these
  services needs any - notably, nginx listens on port 8080 rather than 80
  specifically so that it does not need `NET_BIND_SERVICE`.

### Image security

- **Where the images come from:** all three are built from Dockerfiles written
  for this project, on top of official upstream base images -
  `python:3.12-slim` and `nginx:1.27-alpine` from Docker Hub. `postgres:16` is
  used unmodified.
- **Custom Dockerfiles:** yes, one per service, in `docker/<service>/`.
- **Fixed tags, not `latest`:** every image is tagged `1.0.0`, and base images
  are pinned to specific minor versions. `latest` appears nowhere.
- **Secrets in images:** none. Every credential and endpoint is read from
  environment variables at runtime. `.dockerignore` in each service directory
  excludes `.git`, `.env*`, and the Terraform and Ansible directories from the
  build context, so they cannot end up in a layer by accident.
- **Non-root at runtime:** each Dockerfile creates a dedicated user and switches
  to it with `USER` before the `CMD`.

**Scanning, stated honestly:** the images were **not** scanned with Trivy, Docker
Scout or ECR image scanning as part of this submission. In a real pipeline this
would run in CI on every build and fail the push on critical or high severity
CVEs. This is a known gap rather than an oversight.

### Ingress security

- **How the application is exposed:** through a single Kubernetes Ingress served
  by the ingress-nginx controller, routing to the `frontend` Service only.
  `backend`, `worker` and `postgres` have no Ingress rule and no externally
  reachable Service, so they cannot be reached from outside the cluster by
  construction rather than by configuration.
- **HTTPS:** not enabled in this submission. The host `devops-app.local` is a
  local-only name with no certificate authority willing to issue for it, so a
  valid certificate cannot be obtained. Both the Ingress manifest and the Helm
  chart already support enabling TLS (`ingress.tls.enabled`) with cert-manager or
  AWS ACM once a real, publicly resolvable domain exists.
- **Access restriction:** none beyond the routing itself - there is no IP
  allowlist, rate limiting or authentication at the Ingress layer. For a local
  cluster reachable only from the host machine this is acceptable; a public
  deployment would want at minimum TLS and rate limiting.
- **Public vs internal traffic separation:** the separation is structural rather
  than a second Ingress class - exactly one component is public (`frontend`, via
  the Ingress), and everything else is `ClusterIP`-only. There is no separate
  internal-only Ingress in this submission.
- **WAF:** not configured. On EKS with the AWS Load Balancer Controller, AWS WAF
  would attach at the ALB level.

### AWS permissions - why not IRSA

The assignment recommends IAM Roles for Service Accounts (IRSA) when running on
EKS. **IRSA is not used here because this cluster is not EKS** - IRSA depends on
an EKS-managed OIDC identity provider that a local kind cluster does not have.

The mechanism used instead is a long-lived IAM user access key pair, stored in
the `app-secrets` Kubernetes Secret and picked up from the environment by
`boto3`. Its disadvantages compared to IRSA, stated plainly:

- **Long-lived credentials.** IRSA issues short-lived STS tokens that rotate
  automatically. A static access key remains valid until someone manually
  rotates it, so the window of exposure after a leak is unbounded.
- **Shared across every pod.** All backend and worker pods use the same key, so
  a leak from any one of them compromises the credentials for all of them, and
  CloudTrail cannot distinguish which pod made a given call.
- **No per-ServiceAccount IAM binding.** With IRSA, each ServiceAccount maps to
  its own IAM role with its own policy. Here, backend and worker necessarily
  share one identity, so least privilege can only be applied at the level of
  "what both services together need".
- **The secret exists in more places.** The key must be created, copied, and
  stored in the cluster; IRSA never materializes a credential that can be copied
  at all.

**Migration path on EKS:** create an OIDC provider for the cluster, create one
IAM role per ServiceAccount scoped to exactly what that service needs (backend:
`s3:PutObject` on the specific bucket ARN and `sns:Publish` on the specific topic
ARN), annotate each ServiceAccount with `eks.amazonaws.com/role-arn`, and delete
the access-key entries from the Secret. No application code change is required -
`boto3` picks up the IRSA credentials from the environment automatically.

---

## Trade-offs and compromises

1. **kind instead of EKS.** Chosen for fast iteration and zero AWS compute cost;
   explicitly permitted by the assignment. The cost is: no IRSA, no AWS Load
   Balancer Controller, NetworkPolicy not enforced by the default CNI, and - most
   significantly - no network path to the private RDS instance.

2. **In-cluster PostgreSQL instead of the existing RDS.** Forced by the previous
   decision; analyzed in full in section 13. The application code is unchanged
   and would work against RDS immediately on EKS.

3. **Static IAM access keys instead of IRSA.** Also forced by running outside
   EKS. Analyzed above.

4. **No TLS on the Ingress.** `devops-app.local` cannot receive a CA-issued
   certificate. The configuration hook exists but is disabled.

5. **No image scanning.** Not run for this submission; would belong in CI.

6. **Worker kept intentionally minimal.** Part 2's worker was a systemd service
   running an infinite loop that logged a message every ten seconds and never
   touched RDS, S3 or SNS. That behaviour is preserved exactly rather than
   inventing new business logic for it. The only addition is a heartbeat file
   (`/tmp/healthy`) written on each iteration, so that the readiness and liveness
   probes the assignment requires have something meaningful to check on a service
   that exposes no HTTP endpoint.

7. **`app.py` refactored to read environment variables.** In Part 2, the
   database endpoint, username, password, bucket name and topic ARN were all
   hardcoded as literals in `app.py`. That is incompatible with the requirement
   that no secrets end up inside an image, and with managing configuration
   through ConfigMaps and Secrets. The code now reads all of these from the
   environment; the route logic is otherwise unchanged.

8. **PostgreSQL as a Deployment rather than a StatefulSet.** A single replica
   with `strategy: Recreate` is sufficient for local testing and avoids
   complexity that would not demonstrate anything the assignment asks for. A
   StatefulSet would be correct for any real in-cluster database.

9. **HPA defined but not exercised.** metrics-server was not installed in the
   submitted environment, so the HorizontalPodAutoscaler objects exist and are
   valid but report `<unknown>` for CPU and never trigger a scaling event. The
   manifests are correct; only the metrics source is missing.

10. **NetworkPolicies defined but not enforced.** kind's default CNI does not
    implement NetworkPolicy. The policies are written, apply cleanly, and would
    take effect unchanged under Calico or on EKS - but in this environment they
    document intent rather than actively block traffic.

---

## Manual steps performed

The assignment requires documenting every manual action. These steps are not
automated by the manifests or the chart:

1. **Creating the cluster** - `kind create cluster --name devops-app`.
2. **Installing ingress-nginx and metrics-server** - applied from upstream
   manifests, as shown above. These are cluster add-ons rather than application
   resources, so they are not part of `k8s/` or the chart.
3. **Creating the Secret** - deliberately manual, so real credentials never
   appear in a committed file.
4. **Building and loading the images** - `docker build` and `kind load`, since
   there is no CI pipeline and no registry in this setup.
5. **Recreating the PostgreSQL PVC after changing the database password** -
   necessary because PostgreSQL only applies `POSTGRES_USER` and
   `POSTGRES_PASSWORD` when initializing an empty data directory. This is a
   property of the postgres image, not a misconfiguration.

Everything else - namespace, ServiceAccounts, RBAC, ConfigMap, Deployments,
Services, Ingress, NetworkPolicies, HPA, PDB and the database - is created
declaratively by `kubectl apply -f k8s/` or `helm install`.
