# (f *Function) — The Receiver
Equivalent mental model (if you know Python)

Go:
```
func (f *Function) RunFunction() {
}
```
This function belongs to the `Function` struct.

Python:
```
class Function:
    def RunFunction(self):
        pass
```

***Function — Pointer Receiver**

This means:
```
f *Function
```
is a pointer to a Function struct.

Meaning the method receives the actual object, not a copy.

Example struct:

```
type Function struct {
	log logging.Logger
}
```

Then:

```
func (f *Function) RunFunction(...)
```

means f can access:

```
f.log
```

Which you do here:

```
f.log.Info(...)
```

In the function signature:

```
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
```

This is the actual input from Crossplane:

```
req *fnv1.RunFunctionRequest
```

## RunFunctionRequest
It contains four pieces of information that together describe the entire resource graph Crossplane is reconciling:

```
Observed XR
Observed resources
Desired resources
Pipeline context
```

### Observed XR

This is the actual Composite Resource instance currently in the cluster.

Example Tenant XR:

```
apiVersion: platform.example.io/v1alpha1
kind: Tenant
metadata:
  name: payments
spec:
  name: payments
  dnsName: payments.company.com
  owner:
    team: payments
    email: payments@company.com
```

Inside the request it appears as:

```
req.observed.composite.resource
```

We retrieve it here:

```
xr, err := request.GetObservedCompositeResource(req)
```

And then we read fields like:

```
name, _ := xr.Resource.GetString("spec.name")
dns, _ := xr.Resource.GetString("spec.dnsName")
```

So **Observed XR = the XR Crossplane is reconciling right now**.

### Observed Resources

These are the actual composed resources already running in Kubernetes.

Example resources created by the function:
```
entra-group
gitops-tenant
baseline-tenant
```
Their real state is sent to the function.

Example observed state:

```
observed:
  resources:

    entra-group:
      resource:
        status:
          atProvider:
            objectId: 1234-5678

    gitops-tenant:
      resource:
        status:
          sync:
            status: Synced
          health:
            status: Healthy
```

The function reads them here:

```
observed, err := request.GetObservedComposedResources(req)
```

Then checks:

```
groupRes, ok := observed["entra-group"]
```

So:

```
Observed resources = the real cluster state
```

### Desired Resources

This is the resource graph the pipeline wants to exist.

At the start it might be empty:

```
desired = {}
```

The function builds this graph.

Example:

```
desired[resource.Name(entraGroupResourceName)] = &resource.DesiredComposed{
    Resource: group,
    Ready: groupReady,
}
```

This adds the AzureAD group to the desired graph.

Later you add:

```
gitops-tenant
baseline-tenant
```

So the desired graph becomes:

```
desired:
 ├─ entra-group
 ├─ gitops-tenant
 └─ baseline-tenant
```

Crossplane then creates or updates those resources.

So:

```
Desired resources = what should exist
```

### Pipeline Context

This is shared data between pipeline steps.

Example pipeline:

```
pipeline:
- step: naming
- step: tenant-function
- step: policy
```

Each function can store values in the pipeline context.

Example use case:

Function 1 generates:

```
tenantID
namespaceName
```

Function 2 reads them.

Example conceptual context:

```
context:
  tenantID: t-1234
  namespace: payments
```

The function doesn't use context yet, but it is available in:

```
req.context
```

### The Complete Request Structure

Conceptually the request looks like this:

```
RunFunctionRequest
│
├── observed
│   ├── composite (XR)
│   └── resources
│
├── desired
│   └── resources
│
└── context
```

Graphically:

```
                   Function Input
                        │
                        ▼
               RunFunctionRequest
                        │
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
  Observed XR    Observed Resources   Desired Resources
        │               │                │
        │               │                │
   Tenant XR       Azure Group       (initially empty)
                   Argo App
```

Your function compares observed vs desired.

### This Is the Control Loop

The function always asks:

```
Observed state → what exists?
Desired state → what should exist?
```

Example run #1:

```
Observed resources = none
Desired resources = create Azure group
```

Run #2:

```
Observed resources = Azure group exists
Desired resources = create Argo apps
```

Run #3:

```
Observed resources = all healthy
Desired resources = mark XR ready
```

This is called state convergence.

### How Your Function Uses Each Piece

| Concept            | Where in your code                  |
| ------------------ | ----------------------------------- |
| Observed XR        | `GetObservedCompositeResource(req)` |
| Observed resources | `GetObservedComposedResources(req)` |
| Desired resources  | `GetDesiredComposedResources(req)`  |
| Pipeline context   | `req.GetContext()`                  |

