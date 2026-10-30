#!/usr/bin/env bash
# Creates the secrets the openDesk Argo CD apps need on prod1 and kicks off a refresh:
#   - Secret "opendesk" (master-password, optional smtp-password), read by the helmfile plugin sidecar
#   - an Argo CD credential template for https://github.com/opencollaboration that authenticates as a
#     GitHub App, so every repo the App is installed on (opendesk, infra, ...) is readable over HTTPS
#
# Create the GitHub App first (org settings -> Developer settings -> GitHub Apps -> New):
#   - Repository permissions: Contents read-only (Metadata read-only is added automatically)
#   - Webhook active, URL https://gitops.opencollab.dev/api/webhook (secret: written to a file by this script),
#     subscribed to Push events; "Only on this account"
#   - Generate a private key (.pem) and install the App on opencollaboration, at least on opendesk
#
# Run it logged in to prod1 (oc login ...). gh is only used to look up the installation ID.
# Re-running is safe: existing secrets are left alone unless --force is given.
#
# Usage: scripts/bootstrap-opendesk.sh --app-id <id> --private-key <app.pem> [--installation-id <id>] [--force]
set -euo pipefail

ARGO_NS=opencollab
APP_NS=opencollab-opendesk
GH_ORG=opencollaboration
CREDS_SECRET=creds-github-opencollaboration

FORCE=false
APP_ID=
INSTALLATION_ID=
PRIVATE_KEY=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id) APP_ID=$2; shift 2 ;;
    --installation-id) INSTALLATION_ID=$2; shift 2 ;;
    --private-key) PRIVATE_KEY=$2; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) sed -n '2,16p' "$0" >&2; exit 1 ;;
  esac
done

for tool in oc openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
echo "Cluster: $(oc whoami --show-server) as $(oc whoami)"
oc get namespace "$APP_NS" >/dev/null

exists() { oc -n "$ARGO_NS" get secret "$1" >/dev/null 2>&1; }

# --- openDesk master password ------------------------------------------------------------------
if exists opendesk && ! $FORCE; then
  echo "Secret ${ARGO_NS}/opendesk already exists, skipping (use --force to replace)."
else
  read -rsp "openDesk master password (empty = generate one): " master_password; echo
  if [[ -z "$master_password" ]]; then
    master_password=$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48)
    echo "Generated a master password; it is stored only in ${ARGO_NS}/opendesk."
  fi
  read -rsp "SMTP password (empty = none): " smtp_password; echo

  args=(--from-literal=master-password="$master_password")
  [[ -n "$smtp_password" ]] && args+=(--from-literal=smtp-password="$smtp_password")
  oc -n "$ARGO_NS" create secret generic opendesk "${args[@]}" --dry-run=client -o yaml \
    | oc apply -f -
  unset master_password smtp_password
fi

# --- GitHub App credential template ------------------------------------------------------------
if exists "$CREDS_SECRET" && ! $FORCE; then
  echo "Secret ${ARGO_NS}/${CREDS_SECRET} already exists, skipping (use --force to replace)."
else
  [[ -n "$APP_ID" && -n "$PRIVATE_KEY" ]] || { echo "--app-id and --private-key are required" >&2; exit 1; }
  [[ -r "$PRIVATE_KEY" ]] || { echo "cannot read $PRIVATE_KEY" >&2; exit 1; }

  if [[ -z "$INSTALLATION_ID" ]]; then
    # Needs an org admin token with read:org.
    INSTALLATION_ID=$(gh api "orgs/${GH_ORG}/installations" \
      --jq ".installations[] | select(.app_id == ${APP_ID}) | .id") || true
    [[ -n "$INSTALLATION_ID" ]] || {
      echo "Could not find an installation of App ${APP_ID} on ${GH_ORG}; pass --installation-id" >&2
      echo "(it is the number at the end of the App's Configure URL in the org settings)." >&2
      exit 1
    }
  fi
  echo "GitHub App ${APP_ID}, installation ${INSTALLATION_ID}"

  oc -n "$ARGO_NS" create secret generic "$CREDS_SECRET" \
      --from-literal=type=git \
      --from-literal=url="https://github.com/${GH_ORG}" \
      --from-literal=githubAppID="$APP_ID" \
      --from-literal=githubAppInstallationID="$INSTALLATION_ID" \
      --from-file=githubAppPrivateKey="$PRIVATE_KEY" \
      --dry-run=client -o yaml \
    | oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
    | oc apply -f -
fi

# --- Webhook secret ----------------------------------------------------------------------------
# The App's webhook posts push events to https://gitops.opencollab.dev/api/webhook; Argo CD checks
# their signature against webhook.github.secret in argocd-secret.
if [[ -n "$(oc -n "$ARGO_NS" get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}')" ]] && ! $FORCE; then
  echo "webhook.github.secret is already set in ${ARGO_NS}/argocd-secret, skipping (use --force to replace)."
else
  # Never printed: written to a file only the current user can read, to paste into the App.
  secret_file="${HOME}/argocd-github-webhook-secret.txt"
  (umask 077; openssl rand -hex 32 > "$secret_file")
  oc -n "$ARGO_NS" patch secret argocd-secret --type merge \
    -p "{\"stringData\":{\"webhook.github.secret\":\"$(cat "$secret_file")\"}}" >/dev/null
  echo "Webhook secret written to ${secret_file}: paste it into the GitHub App, then delete the file."
fi

# --- Refresh the apps --------------------------------------------------------------------------
for app in opendesk-object-bucket-claims opendesk; do
  oc -n "$ARGO_NS" annotate applications.argoproj.io "$app" argocd.argoproj.io/refresh=hard --overwrite \
    || echo "Application ${app} not found yet; it picks the credential up when it is created."
done

echo
echo "Done. The helmfile sidecar only appears once the gitops ArgoCD instance reconciles again:"
oc -n "$ARGO_NS" get argocd gitops -o jsonpath='  phase={.status.phase} {.status.conditions[0].message}{"\n"}'
