# Notes

## High level
A controller is split into 3 layers: 
```
API layer        → defines CRDs (what users create)
Controller layer → implements logic (what happens)
Deployment layer → installs everything into Kubernetes
```

```sh
multicluster-tenant/
├── api          ← CRD types (your API)
├── internal     ← controllers (your logic)
├── config       ← Kubernetes manifests (deployment)
├── cmd          ← entrypoint (main.go)
```

## Overview

## 1. `api/` → Your Kubernetes API

```
api/
```
This is where your CRDs are defined in Go.

### What it does
Defines:
```
type Tenant struct {
  Spec   TenantSpec
  Status TenantStatus
}
```

This becomes:
```
apiVersion: m.idp.rezakaramad.local/v1alpha1
kind: Tenant
```

### Mental model
```
api/ = “what users can create”
```

## 2. `internal/` → Your Controllers (business logic)

```
internal/controller/
```
This is where your `TenantReconciler` lives.

### What it does

Implements:
```
Desired state (Spec)
        ↓
Actual state (clusters)
        ↓
Reconcile loop
```

### Mental model
```
internal/ = “what happens when CRD changes”
```

## 3. `cmd/` → Program entrypoint
```
cmd/
```

Contains:
```
main.go
```

### What it does

Bootstraps everything:
```sh
mgr := ctrl.NewManager(...)
controller.SetupWithManager(mgr)
mgr.Start(...)
```

It contains the main program — the thing that runs inside the Kubernetes Pod.

### Mental model
```
cmd/ = “start the controller process”
```

Full system flow
```
Pod starts (Deployment)
        ↓
main.go runs
        ↓
manager starts
        ↓
controller registered
        ↓
watches Tenant
        ↓
Reconcile triggered

```

## 4. `config/` → Kubernetes manifests (deployment)

```
config/
```
This is HUGE — it’s how your controller gets installed.

### Mental model
```
config/ = “how this runs inside Kubernetes”
```

## 5. `test/` → Tests (envtest)
```
test/
```
Used for:
- running controller against a fake API server
- integration-style tests

### Mental model
```
test/ = “simulate Kubernetes locally”
```

## 6. `bin/` → Generated tools
Contains:
- controller-gen
- kustomize
- setup tools

Installed automatically

## 7. `hack/` → Scripts
```
hack/
```
Usually contains helper scripts.

## Makefile
This is your main interface:
```sh
Common commands
make generate    # generate deepcopy, CRDs
make manifests   # generate CRD YAML
make install     # install CRDs in cluster
make run         # run controller locally
make deploy      # deploy to cluster
```
### Mental model
```
Makefile = “kubebuilder CLI wrapper”
```

## `PROJECT` (Kubebuilder metadata)
```
PROJECT
```
Tracks:
- group: `m.idp.rezakaramad.local`
- version: `v1alpha1`
- kind: `Tenant`

Used by kubebuilder internally

## Dockerfile

Builds your controller image

Used by:
```sh
make docker-build
make deploy
```

## Putting It All Together
```sh
User applies Tenant YAML
        ↓
Kubernetes API (CRD from config/)
        ↓
Controller (cmd/ + internal/)
        ↓
Reconcile logic
        ↓
Creates namespaces in clusters
```
