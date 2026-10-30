# OpenCollab Infrastructure Deployments

This repository contains the Kubernetes manifests and configurations for deploying OpenCollab infrastructure 
components using Argo CD.

## Structure

- `argo-cd-apps/`: Contains the Argo CD applications that manage the deployment of the infrastructure components.
  - `argo-cd-apps/apps-of-apps/`: Contains the main Argo CD application that deploys all other applications.
- `components/`: Contains the individual Kubernetes manifests for each infrastructure component.

## Deploying the Infrastructure

To deploy the infrastructure, follow these steps:
1. Install the OKD GitOps Operator in your cluster through the Operator Hub (if it hasn't already by the administrator).
2. Create a new Argo CD application using the `argo-cd-apps/apps-of-apps` directory as the source.
   1. Use the correct overlay for your environment.
3. Wait for the applications to sync and deploy all the components defined in the `components` directory.
## openDesk

openDesk is deployed from its helmfile in `git@github.com:opencollaboration/opendesk.git` by two
applications in `argo-cd-apps/base/opendesk`, rendered by the `helmfile` Config Management Plugin that
runs as a sidecar of the repo server (`components/argocd/base`):

- `opendesk-object-bucket-claims` creates the ODF ObjectBucketClaims openDesk stores its objects in,
  and lets the repo server read them.
- `opendesk` is everything else. Rendering it reads the claims' bucket names and credentials, so it
  reports a ComparisonError until the claims are Bound, then syncs.

Not managed here and needed first:

1. The `opencollab-opendesk` namespace, labelled `argocd.argoproj.io/managed-by=opencollab`.
2. The SCCs and ConfigMaps the openDesk OpenShift patch expects to be provided out of band (see its
   commit message and the comments in its values files).
3. A Secret `opendesk` in `opencollab` with `master-password` (every openDesk password is derived from
   it) and optionally `smtp-password`, read by the plugin sidecar.
4. An Argo CD repository credential for `git@github.com:opencollaboration/opendesk.git`, which is private.
5. DNS for `opencollaboration.dev` and `*.opencollaboration.dev` pointing at the cluster's router; the
   certificate is issued by the `external-issuer` ClusterIssuer (Cloudflare DNS-01).
