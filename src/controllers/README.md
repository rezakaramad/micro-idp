# Note

This project uses **Kubebuilder** to scaffold and manage the Kubernetes controller code. 

**Kubebuilder** generates the project structure, CRDs, controller wiring, RBAC manifests, and provides the standard development workflow (`make generate`, `make manifests`, `make install`, `make run`). 

If you work on this repo again in the future, make sure **Kubebuilder** is installed first, otherwise commands like `kubebuilder init` or or `kubebuilder create api` will not work.

> Quick start and installation guide:  
https://book.kubebuilder.io/quick-start.html

## Project Scaffold

Initialize the project:

```
kubebuilder init \
    --domain rezakaramad.local \
    --repo github.com/rezakaramad/kubepave/src/controllers/tenant
```
Create the Tenant API and controller:
```
kubebuilder create api \
        --group idp \
        --version v1alpha1 \
        --kind Tenant \
        --resource \
        --controller
```
## Development Workflow

Generate deepcopy code:

```
make generate
```
Generate CRDs and RBAC manifests:
```
make manifests
```
Install the CRDs into the cluster:
```
make install
```
Run the controller locally (control plane mode):
```
ROLE=controlplane make run
```
