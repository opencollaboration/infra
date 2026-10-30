#!/usr/bin/env bash
# Temporary workaround while the GitOps operator cannot reconcile the opencollab ArgoCD instance.
#
# The operator builds each managed namespace's application-controller Role from the `admin`
# ClusterRole. The OpsTree redis-operator ClusterRole aggregates a `nonResourceURLs: ["*"]` rule into
# `admin`, which a namespaced Role cannot hold, so every reconcile fails at the Roles and never
# reaches the cluster secret, the repo server or the application controller.
#
# This applies by hand what the operator would produce for opencollab-opendesk and the helmfile
# plugin, taken from the live ArgoCD resource. Once the operator reconciles again it converges on
# the same state; then delete the Role and RoleBindings labelled opencollab.dev/workaround.
#
# Usage: scripts/workaround-gitops-reconcile.sh
set -euo pipefail

ARGO_NS=opencollab
ARGOCD=gitops
APP_NS=opencollab-opendesk

for tool in oc jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
echo "Cluster: $(oc whoami --show-server) as $(oc whoami)"

# --- Permissions in the openDesk namespace -----------------------------------------------------
# A RoleBinding to the admin ClusterRole grants the same rules the operator's Role would, limited
# to this namespace; the nonResourceURLs rule is ignored in a RoleBinding.
for sa in application-controller server; do
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ARGOCD}-argocd-${sa}-admin
  namespace: ${APP_NS}
  labels:
    opencollab.dev/workaround: gitops-reconcile
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: ${ARGOCD}-argocd-${sa}
    namespace: ${ARGO_NS}
EOF
done

# The controller watches every resource type in a managed namespace; admin does not cover all of
# them (e.g. machines.cluster.x-k8s.io), so add the read-only rule the operator's Role starts with.
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ARGOCD}-argocd-application-controller-read
  namespace: ${APP_NS}
  labels:
    opencollab.dev/workaround: gitops-reconcile
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ARGOCD}-argocd-application-controller-read
  namespace: ${APP_NS}
  labels:
    opencollab.dev/workaround: gitops-reconcile
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ARGOCD}-argocd-application-controller-read
subjects:
  - kind: ServiceAccount
    name: ${ARGOCD}-argocd-application-controller
    namespace: ${ARGO_NS}
EOF

# --- Let Argo CD deploy into the namespace -----------------------------------------------------
cluster_secret=${ARGOCD}-default-cluster-config
namespaces=$(oc -n "$ARGO_NS" get secret "$cluster_secret" -o jsonpath='{.data.namespaces}' | base64 -d)
if [[ ",${namespaces}," != *",${APP_NS},"* ]]; then
  oc -n "$ARGO_NS" patch secret "$cluster_secret" --type merge \
    -p "{\"stringData\":{\"namespaces\":\"${namespaces},${APP_NS}\"}}"
else
  echo "${APP_NS} is already in ${cluster_secret}."
fi

# --- Repo server: helmfile plugin sidecar, tools, service account, timeout ---------------------
repo=$(oc -n "$ARGO_NS" get argocd "$ARGOCD" -o json | jq '.spec.repo')
patch=$(jq -n --argjson repo "$repo" '{spec: {template: {spec: {
  serviceAccountName: $repo.serviceaccount,
  automountServiceAccountToken: $repo.mountsatoken,
  initContainers: $repo.initContainers,
  volumes: $repo.volumes,
  containers: ([{
    name: "argocd-repo-server",
    resources: $repo.resources,
    env: [{name: "ARGOCD_EXEC_TIMEOUT", value: "\($repo.execTimeout)s"}]
  }] + $repo.sidecarContainers)
}}}}')
oc -n "$ARGO_NS" patch deployment "${ARGOCD}-repo-server" --type strategic -p "$patch"

# --- Application controller: wait as long as the render takes ----------------------------------
controller_env=$(oc -n "$ARGO_NS" get argocd "$ARGOCD" -o json | jq '.spec.controller.env // []')
oc -n "$ARGO_NS" patch statefulset "${ARGOCD}-application-controller" --type strategic \
  -p "$(jq -n --argjson env "$controller_env" \
        '{spec: {template: {spec: {containers: [{name: "argocd-application-controller", env: $env}]}}}}')"

oc -n "$ARGO_NS" rollout status deployment "${ARGOCD}-repo-server" --timeout=5m
oc -n "$ARGO_NS" rollout status statefulset "${ARGOCD}-application-controller" --timeout=5m

for app in opendesk-object-bucket-claims opendesk; do
  oc -n "$ARGO_NS" annotate applications.argoproj.io "$app" argocd.argoproj.io/refresh=hard --overwrite
done
