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