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

## Marker

Kubebuilder **markers** (`// +kubebuilder:...`) are special annotations written in your Go code that act as instructions for code-generation tools like `controller-gen`.

They do not run at runtime — instead, they are processed when you run commands like:
```
make manifests
```

During this step, markers are used to generate Kubernetes artifacts such as:
- CRDs (CustomResourceDefinitions)
- RBAC permissions
- Validation schemas

For example, you can control:
- whether a resource is namespaced or cluster-scoped
- how fields are validated
- what permissions your controller needs

[Further reading](https://book.kubebuilder.io/reference/markers.html).

Examples:

**Resource-level (CRD behavior)**

Used on the main type:
```
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=ten
```

Controls:
- scope (Namespaced vs Cluster)
- status subresource
- short names, categories

**What is a “subresource”?**
In Kubernetes, a resource can have multiple endpoints.

Example:
```
Tenant
Tenant/status
Tenant/scale
```

Think of it like an API

Instead of one endpoint:
```
/tenants
```
You also get:
```
/tenants/status
```

**Takeaway:**
```
Kubernetes ignores user updates to status because:
the CRD declares status as a separate subresource,
and the API server enforces different rules per endpoint
```

---

I started to understanding the below function in `api/tenant_types.go`:
```
func init() {
	SchemeBuilder.Register(&Tenant{}, &TenantList{})
}
```

First: what problem are we solving?

You have this Go struct:
```
type Tenant struct { ... }
```
And somewhere Kubernetes receives JSON like:
```
{
  "apiVersion": "m.idp.rezakaramad.local/v1alpha1",
  "kind": "Tenant",
  ...
}
```
The system must answer:
```
“How do I turn this JSON into a Go struct?”
```
K8s works with JSON while Go program works with Struct. Something must connect these two worlds. That 'something' is the schema.
Let’s define it very concretely:
```
Scheme = a lookup table (map/dictionary)
```

What does “register Tenant into a scheme” mean?
It simply means:
```
Add an entry to the lookup table
```
Before
```
Scheme = {}
```
After registering
```
Scheme = {
  ("m.idp.rezakaramad.local/v1alpha1", "Tenant") → Tenant struct
}
```
Another way to put this:
```
Put the (apiVersion, kind → Go struct) entry into the Scheme
```

Example (conceptually)
```
Scheme:
("v1", "Pod") → Pod struct
("apps/v1", "Deployment") → Deployment struct
("m.idp.rezakaramad.local/v1alpha1", "Tenant") → Tenant struct
```

In `main.go`:
```
scheme := runtime.NewScheme()
```
This is the real Scheme

It starts empty:
```
{}
```

associate with GroupVersion
When we say:
```
associate Tenant with GroupVersion
```
We mean:
```
("m.idp.rezakaramad.local/v1alpha1", "Tenant") → Tenant struct
```

This is a two-step job:
- First, register the types (e.g. Tenant)
```
SchemeBuilder.Register(&Tenant{}, &TenantList{})
```

- Second, add to the schema ( now it actually updates the schema)
```
AddToScheme(scheme)
```

Why this two-step design?
So multiple files can contribute types cleanly. 

If you multiple types, let's say:
```
api/v1alpha1/
  tenant_types.go
  project_types.go
  team_types.go
```

Each file can register itself and you don't have to add those types in `main.go` because it easily becomes messy over time and for each new type you must remember to update `main.go`. It's easy to forget.

**Kubebuilder solution**

Each file registers itself

File 1: tenant_types.go
```
func init() {
	SchemeBuilder.Register(&Tenant{}, &TenantList{})
}
```
File 2: project_types.go
```
func init() {
	SchemeBuilder.Register(&Project{}, &ProjectList{})
}
```
File 3: team_types.go
```
func init() {
	SchemeBuilder.Register(&Team{}, &TeamList{})
}
```
What happens now

Each file says:
```
“I have types — include me when building the Scheme”
```

Then in `main.go`

You only need ONE line:
```
AddToScheme(scheme)
```

Behind the scenes

All registrations are combined:
``
SchemeBuilder = [
  register Tenant
  register Project
  register Team
]
```

Then:
```
AddToScheme(scheme)
```

runs ALL of them.
