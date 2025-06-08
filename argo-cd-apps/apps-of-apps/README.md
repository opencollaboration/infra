This is the entrypoint for the deployment of everything in this repository to a Kubernetes cluster using Argo CD.

This will deploy the applications defined in the `argo-cd-apps` directory, which will in turn deploy 
the individual components defined in the `components` directory.