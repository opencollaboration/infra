#!/usr/bin/env bash
# Grants the openDesk workloads that need fixed UIDs (or root) the SCCs to run on OpenShift.
#
# Everything else in openDesk runs under restricted-v2. These workloads pin a UID because their
# image needs it (see the openDesk OpenShift patch's values comments). Each gets its own SCC that
# admits only that workload's UID(s), groups, capabilities and volume types, and only its own
# service account may use it, through a Role and RoleBinding in the openDesk namespace.
#
# Run as cluster admin; Argo CD cannot grant SCCs. Re-running is safe (oc apply).
#
# Usage: scripts/grant-opendesk-sccs.sh            create or update the SCCs and grants
#        scripts/grant-opendesk-sccs.sh --delete   remove them again
set -euo pipefail

NS=opencollab-opendesk
LABEL=opencollab.dev/opendesk-scc=true

if [[ "${1:-}" == "--delete" ]]; then
  oc -n "$NS" delete rolebinding,role -l "$LABEL"
  oc delete scc -l "$LABEL"
  exit 0
fi

echo "Cluster: $(oc whoami --show-server) as $(oc whoami)"
oc get namespace "$NS" >/dev/null

# scc <service account> <runAsUser yaml> <fsGroup yaml> <allowPrivilegeEscalation> \
#     <readOnlyRootFilesystem> <requiredDropCapabilities> <allowedCapabilities> <volumes>
scc() {
  local sa=$1 run_as_user=$2 fs_group=$3 escalation=$4 read_only=$5 drop=$6 add=$7 volumes=$8
  local name="opendesk-${sa#opendesk-}"
  oc apply -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: ${name}
  labels:
    opencollab.dev/opendesk-scc: "true"
  annotations:
    kubernetes.io/description: >-
      openDesk ${sa} in ${NS} only (granted through a Role there), admitting just what its pod spec
      needs. Created by opencollaboration/infra scripts/grant-opendesk-sccs.sh.
priority: null
runAsUser: ${run_as_user}
fsGroup: ${fs_group}
supplementalGroups:
  type: MustRunAs
seLinuxContext:
  type: MustRunAs
seccompProfiles: [runtime/default]
allowPrivilegeEscalation: ${escalation}
defaultAllowPrivilegeEscalation: false
readOnlyRootFilesystem: ${read_only}
requiredDropCapabilities: ${drop}
allowedCapabilities: ${add}
defaultAddCapabilities: null
allowPrivilegedContainer: false
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
volumes: ${volumes}
users: []
groups: []
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: use-scc-${name}
  namespace: ${NS}
  labels:
    opencollab.dev/opendesk-scc: "true"
rules:
  - apiGroups: [security.openshift.io]
    resources: [securitycontextconstraints]
    resourceNames: [${name}]
    verbs: [use]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: use-scc-${name}
  namespace: ${NS}
  labels:
    opencollab.dev/opendesk-scc: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: use-scc-${name}
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: ${NS}
EOF
}

# The namespace's own fsGroup range, as restricted-v2 uses.
ns_fsgroup='{type: MustRunAs}'
# Projected is the service account token volume.
volumes_pvc='[configMap, emptyDir, persistentVolumeClaim, projected, secret]'
volumes_no_pvc='[configMap, emptyDir, projected, secret]'

# Dovecot: UID 1000, group 102 owns the maildirs.
scc dovecot '{type: MustRunAs, uid: 1000}' '{type: MustRunAs, ranges: [{min: 102, max: 102}]}' \
  false true '[ALL]' '[]' "$volumes_pvc"

# OX App Suite middleware: UID 1000, for the owner-only chown of its writable dirs.
scc open-xchange-core-mw '{type: MustRunAs, uid: 1000}' "$ns_fsgroup" \
  false true '[ALL]' '[]' "$volumes_no_pvc"

# Postfix: UID 100.
scc postfix '{type: MustRunAs, uid: 100}' "$ns_fsgroup" \
  false true '[ALL]' '[]' "$volumes_pvc"

# Postfix for OX: UID 100, plus 65534 for its listfilter sidecar. An SCC admits one UID or one
# range, so this is the narrowest range covering both (still non-root).
scc postfix-ox '{type: MustRunAsRange, uidRangeMin: 100, uidRangeMax: 65534}' "$ns_fsgroup" \
  false true '[ALL]' '[]' "$volumes_pvc"

# UMC server: UID 999.
scc ums-umc-server '{type: MustRunAs, uid: 999}' "$ns_fsgroup" \
  false true '[ALL]' '[]' "$volumes_no_pvc"

# ClamAV: starts as root and drops to its clamav user itself, so it keeps the runtime's default
# capabilities (SETUID/SETGID/CHOWN among them) and may escalate; it adds none.
scc clamav-simple '{type: MustRunAs, uid: 0}' "$ns_fsgroup" \
  true false '[MKNOD, NET_RAW]' '[]' "$volumes_pvc"

# dkimpy-milter: starts as root and adds exactly these four capabilities to drop privileges.
scc opendesk-dkimpy-milter '{type: MustRunAs, uid: 0}' "$ns_fsgroup" \
  true false '[ALL]' '[CHOWN, DAC_OVERRIDE, SETGID, SETUID]' "$volumes_no_pvc"

echo "Done. The ReplicaSets and StatefulSets retry their rejected pods on their own."
