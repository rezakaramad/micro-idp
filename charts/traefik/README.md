# Traefik

This serves as the primary controller for ingress traffic across all our clusters.

Although Traefik comes with many proprietary features out of the box,
we currently use only standardized features and resources, such as the Gateway API,
to minimize vendor lock-in. As a result, Traefik could be easily replaced with another ingress controller if needed.

Each instance in each cluster is configured to use a statuc IP for the load balancer that is created in the [tofu-project-platform-management](https://github.com/jysk-dev/platform-hub/tree/main/gcp/tofu-project-platform-management) project.

A default Gateway is deployed into each cluster as well.

## Load Balancer IPs and Gateways

- **Management clusters**
  - Static IP: `34.159.139.235`
  - Gateway Hostname: `*.jysk.tech`
- **Tenant Production Cluster**
  - Static IP: `34.141.36.206`
  - Gateway Hostname: `*.prod.jysk.tech`
- **Tenant Test Cluster**
  - Static IP: `34.40.68.148`
  - Gateway Hostname: `*.test.jysk.tech`
- **Tenant Development Cluster**
  - Static IP: `35.198.98.1`
  - Gateway Hostname: `*.dev.jysk.tech`


## Links
- [Traefik Helm Chart](https://github.com/jysk-dev/platform-hub/tree/main/kubernetes/charts/traefik)
- [Traefik Docs](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/)
