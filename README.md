# DevOps on AWS - Rolling Project

This repository contains all stages of the rolling course project in one place.
Each stage builds on the previous one rather than replacing it.

| Stage | What it added | Where it lives |
|---|---|---|
| Part 1 | Manual AWS deployment: 3 EC2 instances, RDS, S3, SNS, nginx | (superseded by Part 2) |
| Part 2 | Infrastructure as Code and configuration management | `terraform/`, `ansible/` |
| Part 3 | Containerization and Kubernetes | `docker/`, `k8s/`, `helm/` |

The application itself is unchanged across stages. What changes is how it is
provisioned, configured, packaged and run.

---

## Table of contents

1. [Repository layout](#1-repository-layout)
2. [Application overview](#2-application-overview)
3. [Infrastructure layer - Terraform](#3-infrastructure-layer---terraform)
4. [Configuration layer - Ansible](#4-configuration-layer---ansible)
5. [Kubernetes architecture](#5-kubernetes-architecture)
6. [Prerequisites](#6-prerequisites)
7. [Building the images](#7-building-the-images)
8. [Creating the cluster and add-ons](#8-creating-the-cluster-and-add-ons)
9. [Creating the Namespace](#9-creating-the-namespace)
10. [Creating the Secrets](#10-creating-the-secrets)
11. [Deploying the application](#11-deploying-the-application)
12. [Verifying the system works](#12-verifying-the-system-works)
13. [Deleting the environment](#13-deleting-the-environment)
14. [Database: why in-cluster PostgreSQL instead of the existing RDS](#14-database-why-in-cluster-postgresql-instead-of-the-existing-rds)
15. [Security](#15-security)
16. [Trade-offs and compromises](#16-trade-offs-and-compromises)
17. [Manual steps performed](#17-manual-steps-performed)

---

## 1. Repository layout

```
.
├── terraform/                    Part 2 - AWS infrastructure as code
│   ├── provider.tf
│   ├── networking.tf             VPC, subnets, route tables, internet gateway
│   ├── security.tf               Security groups
│   ├── keypair.tf
│   ├── ec2.tf                    frontend, backend, worker instances
│   ├── rds.tf                    PostgreSQL instance and subnet group
│   ├── s3.tf
│   ├── sns.tf                    Topic and email subscription
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example  Real tfvars is gitignored
│
├── ansible/                      Part 2 - server configuration
│   ├── ansible.cfg
│   ├── inventory.ini
│   ├── playbook.yml
│   └── roles/
│       ├── common/               Base packages, directories, users
│       ├── nginx/                Reverse proxy install and config
│       ├── backend/              Python runtime, app code, systemd unit
│       └── worker/               Background service and systemd unit
│
├── docker/                       Part 3 - container images
│   ├── frontend/                 Dockerfile, nginx.conf, .dockerignore
│   ├── backend/                  Dockerfile, app.py, requirements.txt
│   └── worker/                   Dockerfile, worker.py, requirements.txt
│
├── k8s/                          Part 3 - plain kubectl manifests
│   ├── namespace.yaml
│   ├── serviceaccounts.yaml      One ServiceAccount per Deployment
│   ├── rbac.yaml                 Namespaced Role and RoleBinding
│   ├── configmap.yaml            Non-sensitive configuration
│   ├── postgres.yaml             In-cluster database (see section 14)
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   ├── worker-deployment.yaml
│   ├── ingress.yaml
│   ├── networkpolicy.yaml        Default-deny plus explicit allow rules
│   ├── hpa.yaml
│   └── pdb.yaml
│
├── helm/devops-app/              Part 3 - equivalent Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/                Same resources, parameterized
│
├── examples/
│   └── secret.example.yaml       Shape of the Secrets, placeholder values only
│
├── architecture/
│   └── k8s-architecture.svg
│
├── screenshots/                  Evidence that the system works
│   ├── 01-kubectl-resources.txt  nodes, namespaces, pods, deployments, services, ingress
│   ├── 02-describe-pod.txt
│   ├── 03-pod-logs.txt
│   ├── 04-application-tests.txt  HTTP, frontend to backend, database, S3
│   ├── 05-restart-resilience.txt Pod deleted and replaced with no downtime
│   ├── 06-trivy-backend.txt      Image vulnerability scan
│   ├── 07-trivy-frontend.txt
│   ├── 08-trivy-worker.txt
│   └── 09-ingress-access.txt     End-to-end request through the Ingress path
│
├── docs/
│   └── part2-README.md           Original Part 2 documentation, kept for reference
│
└── README.md
```

Kubernetes can be deployed **either** with `k8s/` and `kubectl` **or** with the
Helm chart. Both produce the same resources. Do not apply both at once.

**Note on `examples/secret.example.yaml`:** it deliberately lives outside `k8s/`.
If it were inside, `kubectl apply -f k8s/` would overwrite the real Secrets with
its placeholder values - which is exactly what happened during development and
produced `InvalidClientTokenId` errors from AWS. Keeping it in `examples/`
satisfies the requirement to submit an example while making it impossible to
apply by accident.

---

## 2. Application overview

Three services, deliberately simple - the point of the course is how the
application is operated, not how complex it is.

| Service | Role |
|---|---|
| `frontend` | nginx reverse proxy. The only publicly reachable component. |
| `backend` | Flask API. Talks to PostgreSQL, S3 and SNS. |
| `worker` | Background loop. No HTTP interface, no inbound traffic. |

### Backend endpoints

| Endpoint | Method | Behaviour |
|---|---|---|
| `/` | GET | Health check. Used by the readiness and liveness probes. |
| `/users` | GET | Reads all rows from the `users` table. |
| `/add_user` | POST | Inserts a user, then publishes to SNS. |
| `/upload` | POST | Uploads a file to S3, then publishes to SNS. |

The health check deliberately does **not** touch the database. If it did, a
transient database outage would fail the liveness probe and Kubernetes would
kill every healthy backend pod. The probe answers "is my process responding",
not "are all my dependencies up".

---

## 3. Infrastructure layer - Terraform

`terraform/` provisions everything that lives in AWS.

**What it creates:**

- **Networking** - VPC, one public subnet (frontend), two private subnets
  (backend and worker), internet gateway, route tables
- **Security groups** - minimal rules per tier
- **EC2** - three instances, one per service, with the frontend public and the
  other two private
- **RDS** - PostgreSQL (`project-db`, database `projectdb`) in a subnet group
  spanning the private subnets, with `publicly_accessible = false`
- **S3** - bucket for uploads
- **SNS** - topic plus an email subscription

**Running it:**

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill in real values
terraform init
terraform plan
terraform apply
```

Tearing down:

```bash
terraform destroy
```

**State:** the Terraform state file is local and gitignored. It contains
credentials in plaintext, so it must never be committed. For team use it would
move to a remote backend (S3 with DynamoDB locking).

**Variables** are declared in `variables.tf`; `db_password` is marked
`sensitive = true` so Terraform does not print it in plan or apply output.

---

## 4. Configuration layer - Ansible

`ansible/` configures the servers that Terraform created. Terraform builds empty
machines; Ansible installs and starts what runs on them.

**Roles:**

| Role | What it does |
|---|---|
| `common` | Package updates, base packages, directories, application user |
| `nginx` | Installs nginx, renders the reverse proxy config from a template |
| `backend` | Python runtime, dependencies, application code, systemd unit |
| `worker` | Background service and its systemd unit |

**Running it:**

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml
```

**Note:** `inventory.ini` contains the IP addresses of the Part 2 EC2 instances.
Those addresses are stale - the instances may no longer exist, and would need
to be repopulated from `terraform output` before running Ansible again.

### Why Kubernetes replaces this for Part 3

The Ansible `backend` role ends by creating a systemd unit with
`Restart=always`. That covers one failure mode: the process crashing. It does
not cover a process that hangs while still running, and it does nothing at all
if the machine itself dies.

| Failure | systemd (Part 2) | Kubernetes (Part 3) |
|---|---|---|
| Process crashes | Restarts it | Restarts it |
| Process hangs but stays up | Not detected | livenessProbe detects it |
| Machine dies | Nothing happens | Pod is rescheduled elsewhere |
| Scaling | Manual | `replicas`, or automatic via HPA |
| Version upgrade | Downtime | Rolling update, no downtime |

---

## 5. Kubernetes architecture

```
                            User (HTTP)
                                 |
                                 v
                    Ingress (ingress-nginx controller)
                                 |
                                 v
                   frontend Service (ClusterIP, port 80)
                                 |
                                 v
                   frontend Pods - nginx, 2 replicas, port 8080
                                 |
                                 v
                   backend Service (ClusterIP, port 5000)
                                 |
                                 v
                   backend Pods - Flask, 2 replicas (HPA 2-6)
                                 |
              +------------------+------------------+
              v                  v                  v
      postgres Service      S3 bucket           SNS topic
       (in-cluster)         (real AWS)          (real AWS)
              |
              v
      postgres Pod + PVC

      worker Pod - background loop, 1 replica
      (no Service, no Ingress - outbound only)
```

Full diagram: `architecture/k8s-architecture.svg`.

### Inside the cluster vs outside

**Inside:** frontend, backend, worker, postgres.

**Outside (real AWS services in use):**
- **S3** - bucket `ayelet-backend-bucket`, written by `/upload`
- **SNS** - topic `project-alerts`, published to by `/add_user` and `/upload`

**Outside (present but not used by this deployment):**
- **RDS** - `project-db`, created by Terraform in Part 2. Unreachable from a
  local cluster; see section 14.

---

## 6. Prerequisites

```bash
docker --version
kubectl version --client
kind version
helm version        # only if using the Helm path
```

Plus AWS credentials for an IAM user allowed to write to the S3 bucket and
publish to the SNS topic.

---

## 7. Building the images

From the repository root:

```bash
docker build -t devops-app-frontend:1.0.1 docker/frontend
docker build -t devops-app-backend:1.0.1  docker/backend
docker build -t devops-app-worker:1.0.1   docker/worker
```

Image tags are pinned to `1.0.1`. `latest` is never used, so every rollout is
reproducible and `kubectl rollout undo` has a meaningful target.

Python dependencies are also pinned to the exact versions that were tested
(`Flask==3.1.3`, `psycopg2-binary==2.9.12`, `boto3==1.43.61`) for the same
reason. Note that pinning direct dependencies does not pin transitive ones -
`boto3==1.43.61` still resolves `botocore` to any release matching
`<1.44.0,>=1.43.61`. Fully reproducible builds would require a lockfile
produced by `pip-compile` or `pip freeze` over the whole tree.

### Loading into the cluster

Because the cluster is local, images are loaded directly rather than pushed:

```bash
kind load docker-image devops-app-frontend:1.0.1 --name devops-app
kind load docker-image devops-app-backend:1.0.1  --name devops-app
kind load docker-image devops-app-worker:1.0.1   --name devops-app
```

Pushing to a real registry instead would be:

```bash
docker tag devops-app-backend:1.0.1 <registry>/devops-app-backend:1.0.1
docker push <registry>/devops-app-backend:1.0.1
```

and then updating `image:` in the Deployments, or `image.registry` in
`helm/devops-app/values.yaml`.

### Scanning the images

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity HIGH,CRITICAL --scanners vuln \
  devops-app-backend:1.0.1
```

Results for all three images are in `screenshots/06-trivy-*.txt`. See the image
security subsection of section 15 for how to read them.

---

## 8. Creating the cluster and add-ons

```bash
kind create cluster --name devops-app
```

Ingress controller:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

metrics-server, required for the HorizontalPodAutoscaler to read CPU:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Note:** metrics-server was not installed in the submitted environment. The
HPA objects are defined and apply cleanly, but without a metrics source they
report `<unknown>` for CPU and never scale. The step above is what would make
them functional.

**After a host restart:** the kind container gets a new port, so kubectl needs
to be resynchronised:

```bash
docker start devops-app-control-plane
kind export kubeconfig --name devops-app
```

---

## 9. Creating the Namespace

All application resources run in a dedicated namespace, never `default`:

```bash
kubectl apply -f k8s/namespace.yaml
```

---

## 10. Creating the Secrets

Secrets are **split by purpose** so that each service receives only what it
actually needs:

| Secret | Contains | Consumed by |
|---|---|---|
| `db-secrets` | `DB_USER`, `DB_PASSWORD` | backend, postgres |
| `aws-secrets` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | backend only |

The worker receives **no Secret at all** - it uses only the standard library
and never touches the database or AWS. PostgreSQL never sees the AWS
credentials.

```bash
kubectl create secret generic db-secrets -n devops-app \
  --from-literal=DB_USER=app \
  --from-literal=DB_PASSWORD='REPLACE_ME'

kubectl create secret generic aws-secrets -n devops-app \
  --from-literal=AWS_ACCESS_KEY_ID='REPLACE_ME' \
  --from-literal=AWS_SECRET_ACCESS_KEY='REPLACE_ME'
```

Creating them imperatively means the real values exist only in the shell and in
the cluster - never in a file that could be committed.
`examples/secret.example.yaml` documents the shape for reviewers.

**Important:** if the PostgreSQL password changes after the database has already
initialized, the change has no effect. PostgreSQL only creates its user on first
startup with an empty data directory. Applying a new password requires deleting
the PersistentVolumeClaim:

```bash
kubectl delete deployment postgres -n devops-app
kubectl delete pvc postgres-pvc -n devops-app
kubectl apply -f k8s/
```

---

## 11. Deploying the application

**With kubectl:**

```bash
kubectl apply -f k8s/
```

**With Helm:**

```bash
helm install devops-app ./helm/devops-app \
  --set secrets.dbUser=app \
  --set secrets.dbPassword="$DB_PASSWORD" \
  --set secrets.awsAccessKeyId="$AWS_ACCESS_KEY_ID" \
  --set secrets.awsSecretAccessKey="$AWS_SECRET_ACCESS_KEY"

# subsequent updates
helm upgrade --install devops-app ./helm/devops-app
```

Verifying the chart renders before installing:

```bash
helm template devops-app ./helm/devops-app
```

This produces 26 objects: 4 Deployments, 3 Services, 3 ServiceAccounts,
5 NetworkPolicies, 2 ConfigMaps, 2 Secrets, 2 PodDisruptionBudgets, plus the
Namespace, PVC, Role, RoleBinding, HPA and Ingress.

---

## 12. Verifying the system works

Captured outputs are in `screenshots/`.

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

Expected: six pods - 2 frontend, 2 backend, 1 worker, 1 postgres.

### End-to-end through the Ingress

This is the real external entry path, not a port-forward shortcut:

```bash
NODE_IP=$(docker inspect devops-app-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}')

curl -s -H "Host: devops-app.local" http://$NODE_IP:31866/
# {"message":"app is running"}

curl -s -H "Host: devops-app.local" http://$NODE_IP:31866/users
# [[1,"..."],[2,"..."]]
```

The `Host` header matches the Ingress rule, so the ingress-nginx controller
routes to the frontend Service without needing an `/etc/hosts` entry. A single
successful response exercises the whole chain: ingress controller, Ingress rule,
frontend Service, nginx, backend Service, Flask, PostgreSQL.

For quick local testing, `kubectl port-forward -n devops-app svc/frontend
8080:80` also works, but it bypasses the Ingress and proves less.

### Application to database

```bash
curl -s -X POST http://$NODE_IP:31866/add_user \
  -H "Host: devops-app.local" -H "Content-Type: application/json" \
  -d '{"name":"test-user"}'
# {"status":"user added"}
```

### Application to S3 and SNS

```bash
echo "test" > /tmp/testfile.txt
curl -s -X POST -H "Host: devops-app.local" \
  -F "file=@/tmp/testfile.txt" http://$NODE_IP:31866/upload
# {"status":"file uploaded"}

aws s3 ls s3://ayelet-backend-bucket/
```

A successful `{"status": ...}` response is itself proof that SNS worked: in
`app.py`, `sns.publish()` runs after the database write and before the response
is returned, so any SNS failure surfaces as an HTTP 500. The email subscriber on
`project-alerts` also receives the notification.

### Pod restart resilience

```bash
kubectl get pods -n devops-app
kubectl delete pod <backend-pod-name> -n devops-app
curl -s -H "Host: devops-app.local" http://$NODE_IP:31866/
kubectl get pods -n devops-app
```

The Deployment creates a replacement immediately. Because backend runs two
replicas and the readiness probe keeps the new pod out of the Service until it
is healthy, requests continue to be served with no downtime.

---

## 13. Deleting the environment

```bash
# Kubernetes
kubectl delete -f k8s/
kubectl delete secret db-secrets aws-secrets -n devops-app
kind delete cluster --name devops-app

# or, if deployed with Helm
helm uninstall devops-app
```

`kubectl delete -f k8s/` removes the PersistentVolumeClaim as well, so all
database data is lost.

AWS resources are managed by Terraform:

```bash
cd terraform
terraform destroy
```

---

## 14. Database: why in-cluster PostgreSQL instead of the existing RDS

This is the most significant architectural decision in the project.

### The original intention

Reuse the RDS instance created by Terraform in Part 2 (`project-db`, database
`projectdb`), exactly as the assignment suggests as its first option. That would
keep a single source of truth for data across all stages.

### Why it turned out to be impossible from a local cluster

The Terraform code creates the instance like this:

```hcl
resource "aws_db_instance" "postgres" {
  identifier             = "project-db"
  db_name                = "projectdb"
  db_subnet_group_name   = aws_db_subnet_group.main.name   # private subnets only
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = false
}
```

Two properties make it unreachable:

1. **`publicly_accessible = false`** - AWS assigns no public address and no
   publicly resolvable DNS record. The endpoint resolves only inside the VPC.
2. **Private subnets only** - the subnet group spans
   `private_subnet_backend` and `private_subnet_worker`, neither of which has a
   route to the internet gateway.

The kind cluster runs on a local machine, entirely outside AWS. Its pods have no
presence in the VPC, so they can never reach a private RDS endpoint.

**This cannot be fixed with a Security Group.** Security Groups filter traffic
that has already reached the VPC; they cannot create a network path that does
not exist. Opening port 5432 to the local machine's address would have no
effect whatsoever.

### Options considered

| Option | Why not chosen |
|---|---|
| Set `publicly_accessible = true` | Exposes a production-shaped database to the internet for the convenience of a local test environment, contradicting the network security requirements of Parts 2 and 3. |
| Deploy on EKS | Technically correct - pods in the VPC reach RDS over private networking with no code change. Not chosen because of the cost of running an EKS control plane and node group, and because the assignment explicitly permits kind. |
| VPN or bastion tunnel | Significant setup, teaches nothing about Kubernetes. |
| **In-cluster PostgreSQL** | **Chosen.** Explicitly permitted: "for practice purposes only, provided it is explained why this is less appropriate for production". |

### Why in-cluster PostgreSQL is not appropriate for production

- **Storage durability** - data lives in a PVC backed by the node's local disk.
  Lose the node, lose the data. RDS replicates across Availability Zones.
- **No automated backups or point-in-time recovery** - `kubectl delete pvc`
  destroys the data irrecoverably.
- **No high availability** - a single replica. If the pod dies the database is
  down until it restarts. RDS Multi-AZ fails over automatically.
- **Wrong controller for a stateful workload** - a StatefulSet is correct for
  in-cluster databases, giving stable network identity and per-replica storage.
  A Deployment with `strategy: Recreate` is used here only because a single
  replica suffices for local testing.
- **Manual version upgrades** - RDS patches minor versions in a maintenance
  window; here it means changing an image tag and hoping the on-disk format is
  compatible.
- **Static credentials** - RDS integrates with Secrets Manager for rotation. The
  in-cluster password is a static Kubernetes Secret.

### What would change on EKS

The application code requires **no changes at all** - a deliberate design goal.
`app.py` reads every connection parameter from the environment, so switching
back to RDS means only:

1. Deleting `k8s/postgres.yaml`.
2. Changing four values: `DB_HOST` to the RDS endpoint, `DB_NAME` to `projectdb`,
   and the two credentials in `db-secrets`.
3. Allowing the EKS node group's security group in the RDS security group on
   port 5432.

The NetworkPolicy already permits egress from backend and worker on 5432, so no
policy change would be needed.

### S3 and SNS are unaffected

Unlike RDS, S3 and SNS are public AWS API endpoints reachable over HTTPS from
anywhere. A pod in a local cluster calls them normally given valid credentials.
`/upload` writes to the real bucket; `/add_user` and `/upload` publish to the
real topic.

---

## 15. Security

### Permission separation - ServiceAccounts

Each Deployment runs under its own ServiceAccount:

| Deployment | ServiceAccount | API token mounted | RBAC |
|---|---|---|---|
| `frontend` | `frontend-sa` | No | None |
| `backend` | `backend-sa` | No | Read-only Role |
| `worker` | `worker-sa` | No | None |

None of these services talks to the Kubernetes API - they talk to nginx, Flask
routes, PostgreSQL and AWS. `automountServiceAccountToken: false` is set on all
three, so a compromised pod has no API token to steal in the first place.

**Why not one shared account:** a single shared identity means a vulnerability
anywhere - an unpatched dependency in the backend, a misconfigured nginx -
grants the attacker everything that account can do, across all services.
Separate accounts mean a frontend compromise cannot act as the backend.

### RBAC

`k8s/rbac.yaml` defines:

- **Role** `devops-app-readonly`, namespaced, granting `get`, `list` and `watch`
  on `configmaps` and `pods` only
- **RoleBinding** `backend-readonly-binding`, binding it to `backend-sa` only

`frontend-sa` and `worker-sa` have no RoleBinding at all.

**No workload is bound to `cluster-admin` or any cluster-scoped Role.** All RBAC
is namespace-scoped.

Stated honestly: even `backend-sa` does not currently need these permissions -
it never calls the API and its token is not mounted. The Role demonstrates
least-privilege RBAC as required, scoped as narrowly as possible rather than
granted broadly.

### Secrets management

- **Where** - two Kubernetes Secrets in the `devops-app` namespace, split by
  purpose (`db-secrets`, `aws-secrets`), injected via `envFrom` and
  `secretKeyRef`
- **How created** - imperatively with `kubectl create secret`, so real values
  never touch a file in the repository
- **What is committed** - only `examples/secret.example.yaml` with placeholders,
  deliberately outside `k8s/` so it cannot overwrite the real Secrets
- **Which tools** - Kubernetes Secrets only. No Sealed Secrets, External Secrets
  Operator or AWS Secrets Manager.

**Limitation, stated plainly:** Kubernetes Secrets are base64-encoded, not
encrypted, unless encryption at rest is configured on etcd. Anyone with
`get secret` in the namespace reads them in plaintext. The production upgrade
path is AWS Secrets Manager with the External Secrets Operator, which
centralizes secrets, supports rotation and produces an audit trail.

### Network security

`networkpolicy.yaml` starts from **default-deny** for both directions across the
namespace, then allows only what is needed:

| Component | Accepts traffic from | Can connect to |
|---|---|---|
| `frontend` | ingress-nginx namespace only | `backend` on 5000, DNS |
| `backend` | `frontend` only, on 5000 | `postgres` on 5432, 443 for AWS, DNS |
| `worker` | **Nobody** - no ingress rule | `postgres` on 5432, 443, DNS |
| `postgres` | `backend` and `worker` only, on 5432 | DNS only |

Note that access to port 5432 is scoped to pods labelled `postgres` rather than
being open to any destination - the database is not reachable on that port
except where it actually lives.

**Who can reach the database:** only backend and worker, from inside the
namespace. PostgreSQL has no Ingress, no NodePort and no LoadBalancer Service.

**What is exposed externally:** only `frontend`, and only through the Ingress.

**Enforcement caveat:** kind's default CNI (kindnet) does not enforce
NetworkPolicy. The policies apply cleanly and are correct, but in the submitted
environment they document intent rather than actively blocking traffic. Under
Calico or on EKS they take effect unchanged:

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

### Container security

Every pod sets, at pod level:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: <uid>
  runAsGroup: <gid>
  fsGroup: <gid>
  seccompProfile:
    type: RuntimeDefault
```

and at container level:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

- **Non-root** - backend and worker run as uid 1000 (a dedicated `appuser`
  created in their Dockerfiles), frontend as uid 101 (nginx's built-in user),
  postgres as uid 999.
- **No privilege escalation** - blocks setuid-based escalation paths.
- **Read-only root filesystem** - the only writable paths are explicit
  `emptyDir` volumes: `/tmp` for backend and worker, and `/tmp`,
  `/var/cache/nginx`, `/var/run` for nginx. This is why `nginx.conf` redirects
  every temp path into `/tmp`.
- **Minimal capabilities** - all dropped. Notably, nginx listens on 8080 rather
  than 80 specifically so it does not need `NET_BIND_SERVICE`.

PostgreSQL is the one exception: it runs non-root with capabilities dropped and
escalation disabled, but without `readOnlyRootFilesystem`, since the postgres
image writes to several paths outside its data volume during startup.

### Image security

- **Sources** - all three built from Dockerfiles written for this project, on
  official upstream bases (`python:3.12-slim`, `nginx:1.27-alpine`).
  `postgres:16` is used unmodified.
- **Fixed tags** - every image tagged `1.0.1`; base images pinned to minor
  versions. `latest` appears nowhere.
- **No secrets in images** - every credential and endpoint is read from the
  environment at runtime. `.dockerignore` excludes `.git`, `.env*`, and the
  Terraform and Ansible directories from the build context, so they cannot end
  up in a layer by accident.
- **Non-root at runtime** - each Dockerfile creates a user and switches to it
  with `USER` before `CMD`.
- **Dependencies pinned** to tested versions.

**Scanning results** (Trivy, HIGH and CRITICAL only, full output in
`screenshots/06-trivy-*.txt`):

| Image | Findings |
|---|---|
| `devops-app-backend:1.0.1` | 26 (22 HIGH, 4 CRITICAL) |
| `devops-app-frontend:1.0.1` | 35 (33 HIGH, 2 CRITICAL) |
| `devops-app-worker:1.0.1` | 26 (22 HIGH, 4 CRITICAL) |

Reading these numbers matters more than the totals:

- **Every finding is in the base OS layer, none in application code or Python
  dependencies.** All 17 Python packages scan clean. The findings are in
  `perl-base`, `openssl`, `ncurses`, `util-linux` and similar - packages that
  ship with the base image and are not used by the application.
- **Only two of the backend's 26 have a fix available** (`openssl` and
  `libssl3t64`, fixed in `3.5.6-1~deb13u2`). The rest are marked `affected` or
  `fix_deferred` - Debian has not released a patch.

Adding `apt-get upgrade` to the Dockerfile would pick up the two fixable ones,
but at the cost of reproducibility: every rebuild would pull whatever is current
at that moment. The more meaningful remediation is a smaller base -
`python:3.12-alpine` or a distroless image - which removes most of the
vulnerable packages entirely rather than patching them. That is a larger change
than this stage warrants, and is recorded here as the known next step.

In a real pipeline this scan would run in CI on every build and block the push
on critical severities.

### Ingress security

- **How exposed** - a single Ingress served by ingress-nginx, routing only to
  the frontend Service. Backend, worker and postgres have no Ingress rule and no
  externally reachable Service, so they are unreachable from outside by
  construction rather than by configuration.
- **HTTPS** - not enabled. `devops-app.local` is a local-only name that no
  certificate authority will issue for. Both the Ingress and the Helm chart
  support enabling TLS (`ingress.tls.enabled`) with cert-manager or ACM once a
  real domain exists.
- **Access restriction** - none beyond the routing itself. No IP allowlist, rate
  limiting or authentication at the Ingress layer. Acceptable for a local
  cluster; a public deployment would want at minimum TLS and rate limiting.
- **Public vs internal separation** - structural rather than a second Ingress
  class: exactly one component is public, everything else is ClusterIP-only.
- **WAF** - not configured. On EKS with the AWS Load Balancer Controller, AWS
  WAF would attach at the ALB level.

### AWS permissions - why not IRSA

IRSA is recommended on EKS, and **is not usable here because this cluster is not
EKS** - it depends on an EKS-managed OIDC provider that kind does not have.

The mechanism used instead is a long-lived IAM access key pair in the
`aws-secrets` Secret, picked up from the environment by `boto3`. Its
disadvantages compared to IRSA:

- **Long-lived credentials** - IRSA issues short-lived STS tokens that rotate
  automatically. A static key stays valid until manually rotated, so the
  exposure window after a leak is unbounded.
- **Shared across pods** - all backend pods use the same key, so a leak from any
  one compromises all of them, and CloudTrail cannot distinguish which pod made
  a call.
- **No per-ServiceAccount IAM binding** - with IRSA each ServiceAccount maps to
  its own IAM role and policy.
- **The secret exists in more places** - it must be created, copied and stored.
  IRSA never materializes a credential that can be copied at all.

Splitting `aws-secrets` from `db-secrets` limits the blast radius as far as
Kubernetes allows: only the backend pods receive the AWS credentials at all.

**Migration path on EKS:** create an OIDC provider, create one IAM role per
ServiceAccount scoped to exactly what that service needs (`s3:PutObject` on the
specific bucket ARN, `sns:Publish` on the specific topic ARN), annotate the
ServiceAccount with `eks.amazonaws.com/role-arn`, and delete the access-key
Secret. No application code change is required.

### A note on git history

During development, `terraform/terraform.tfvars` was committed before
`.gitignore` covered it. The file was later removed, but **removing a file does
not remove it from git history** - it remains retrievable from earlier commits.
The database password has since been rotated. The lesson recorded here:
`.gitignore` must be correct before the first commit, not after.

GitHub's secret scanner also flagged three findings in this repository. All
three are example values inside AWS CLI documentation files that were vendored
into `terraform/aws/` (since removed), not real credentials.

---

## 16. Trade-offs and compromises

1. **kind instead of EKS.** Fast iteration and zero AWS compute cost; explicitly
   permitted. The cost: no IRSA, no AWS Load Balancer Controller, NetworkPolicy
   not enforced by the default CNI, and no network path to the private RDS
   instance.

2. **In-cluster PostgreSQL instead of the existing RDS.** Forced by the previous
   decision; analyzed in full in section 14. The application code is unchanged
   and would work against RDS immediately on EKS.

3. **Static IAM access keys instead of IRSA.** Also forced by running outside
   EKS. Mitigated by splitting the AWS credentials into their own Secret.

4. **No TLS on the Ingress.** `devops-app.local` cannot receive a CA-issued
   certificate. The configuration hook exists but is disabled.

5. **Trivy findings not remediated.** The scan runs and is documented, but the
   base-image CVEs are left in place - most have no available fix, and the
   meaningful remediation (a smaller base image) is a larger change.

6. **Worker kept intentionally minimal.** Part 2's worker was a systemd service
   running a loop that logged a message every ten seconds and never touched RDS,
   S3 or SNS. That behaviour is preserved rather than inventing new business
   logic. The only addition is a heartbeat file (`/tmp/healthy`) written each
   iteration, so the required probes have something meaningful to check on a
   service with no HTTP endpoint.

7. **`app.py` refactored to read environment variables.** In Part 2 the database
   endpoint, credentials, bucket name and topic ARN were hardcoded literals.
   That is incompatible with keeping secrets out of images and with managing
   configuration through ConfigMaps and Secrets. The route logic is otherwise
   unchanged.

8. **PostgreSQL as a Deployment rather than a StatefulSet.** A single replica
   with `strategy: Recreate` suffices for local testing and avoids complexity
   that would not demonstrate anything the assignment asks for.

9. **HPA defined but not exercised.** metrics-server was not installed, so the
   HPA objects are valid but report `<unknown>` for CPU and never trigger.

10. **NetworkPolicies defined but not enforced.** kind's default CNI does not
    implement NetworkPolicy. The policies would take effect unchanged under
    Calico or on EKS.

11. **Flask development server in the image.** `app.run()` is Flask's built-in
    server. Production would use gunicorn with worker and timeout settings and
    graceful shutdown.

12. **Limited request validation in the application.** `/upload` uses the
    client-supplied filename as the S3 object key with no size or type limits or
    collision handling, and error handling around the database is minimal. Both
    would need hardening before this endpoint could be considered
    production-safe.

---

## 17. Manual steps performed

The assignment requires documenting every manual action. These are not
automated by the manifests or the chart:

1. **Creating the cluster** - `kind create cluster --name devops-app`.
2. **Installing ingress-nginx and metrics-server** - cluster add-ons applied
   from upstream manifests, not application resources.
3. **Creating the Secrets** - deliberately manual, so real credentials never
   appear in a committed file.
4. **Building and loading the images** - `docker build` and `kind load`, since
   there is no CI pipeline and no registry in this setup.
5. **Recreating the PostgreSQL PVC after a password change** - required because
   PostgreSQL only applies `POSTGRES_USER` and `POSTGRES_PASSWORD` when
   initializing an empty data directory. This is a property of the postgres
   image, not a misconfiguration.
6. **Re-exporting the kubeconfig after a host restart** -
   `kind export kubeconfig --name devops-app`, because the kind container's
   published port changes when it restarts.
7. **Running the Trivy scans** - would move into CI in a real pipeline.

Everything else - namespace, ServiceAccounts, RBAC, ConfigMap, Deployments,
Services, Ingress, NetworkPolicies, HPA, PDB and the database - is created
declaratively by `kubectl apply -f k8s/` or `helm install`.
