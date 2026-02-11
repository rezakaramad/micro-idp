# External Secret

Authentication to GCP is handled via Workload Identity Federation, removing the need for long-lived credentials.

The Google Service Account and required IAM roles are created using Config Connector as part of the Helm chart.
While the Helm chart is deployed on all clusters, the Service Account itself is provisioned only from the Management cluster.

All External Secret instances across the platform share this same Google Service Account.
Tenant isolation is achieved by using namespace-scoped `SecretStore` resources, ensuring secrets are accessible only within the tenant’s namespace.

- Google Service Account: `external-secrets@jysk-platform.iam.gserviceaccount.com`

Each tenant is provisioned with a `SecretStore` resource in each of its Kubernetes environment namespaces.
This allows the tenant to request secrets from Google Secret Manager in the corresponding Google Cloud project for that environment.

When a new secret is created in Google Secret Manager and an `ExternalSecret` resource is deployed, the secret is automatically
synchronized into the target namespace, where it can be consumed by workloads.


## Links
- [External Secret Helm Chart](https://github.com/jysk-dev/platform-hub/tree/docs/kubernetes/charts/external-secrets)
- [External Secret Docs](https://external-secrets.io/latest/)
