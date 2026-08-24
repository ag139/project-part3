#!/usr/bin/env bash
# Idempotent health check for the whole platform.
# Safe to run at any time; changes nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
pass() { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

echo "==> cluster"
if kubectl cluster-info >/dev/null 2>&1; then
  pass "API server reachable"
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
  TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ] \
    && pass "all $TOTAL nodes Ready" \
    || fail "$READY of $TOTAL nodes Ready"
else
  fail "cannot reach the API server. Run: kind export kubeconfig --name devops-ci"
  exit 1
fi

echo "==> namespaces"
for ns in jenkins devops-app ingress-nginx; do
  kubectl get namespace "$ns" >/dev/null 2>&1 \
    && pass "namespace $ns exists" \
    || fail "namespace $ns missing"
done

echo "==> jenkins"
if kubectl get statefulset jenkins -n jenkins >/dev/null 2>&1; then
  READY=$(kubectl get statefulset jenkins -n jenkins -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${READY:-0}" -ge 1 ] && pass "controller Ready" || fail "controller not Ready"
else
  fail "Jenkins is not installed"
fi

kubectl get pvc jenkins -n jenkins -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound \
  && pass "persistent volume Bound" || fail "persistent volume not Bound"

echo "==> identities and permissions"
for sa in jenkins-controller jenkins-ci jenkins-cd; do
  kubectl get serviceaccount "$sa" -n jenkins >/dev/null 2>&1 \
    && pass "ServiceAccount $sa exists" \
    || fail "ServiceAccount $sa missing"
done

kubectl auth can-i update deployments -n devops-app \
  --as=system:serviceaccount:jenkins:jenkins-cd 2>/dev/null | grep -q yes \
  && pass "deployer may update deployments" \
  || fail "deployer cannot update deployments"

[ "$(kubectl auth can-i delete deployments -n devops-app \
     --as=system:serviceaccount:jenkins:jenkins-cd 2>/dev/null)" = "no" ] \
  && pass "deployer may NOT delete deployments, as intended" \
  || fail "deployer can delete deployments, which is too permissive"

[ "$(kubectl auth can-i list pods -n devops-app \
     --as=system:serviceaccount:jenkins:jenkins-ci 2>/dev/null)" = "no" ] \
  && pass "CI identity has no access to the application namespace, as intended" \
  || fail "CI identity can reach the application namespace"

echo "==> credentials"
kubectl get secret dockerhub-creds -n jenkins >/dev/null 2>&1 \
  && pass "registry credential present" \
  || fail "registry credential missing"

kubectl get secret dockerhub-creds -n jenkins \
  -o jsonpath='{.metadata.labels.jenkins\.io/credentials-type}' 2>/dev/null \
  | grep -q usernamePassword \
  && pass "credential is labelled for Jenkins" \
  || fail "credential is missing the Jenkins label"

echo "==> jobs"
for job in seed-job ci-application cd-application; do
  kubectl exec -n jenkins jenkins-0 -c jenkins -- \
    test -d "/var/jenkins_home/jobs/$job" 2>/dev/null \
    && pass "job $job exists" \
    || fail "job $job missing. Run seed-job once."
done

echo "==> application"
for dep in frontend backend worker postgres; do
  READY=$(kubectl get deployment "$dep" -n devops-app -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${READY:-0}" -ge 1 ] && pass "$dep Ready" || fail "$dep not Ready"
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "all checks passed"
else
  echo "one or more checks failed"
fi
exit "$FAIL"
