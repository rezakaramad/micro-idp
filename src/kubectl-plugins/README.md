# kubectl-plugins

## Name the Plugin Correctly
Kubectl discovers plugins based on this naming pattern:
```
kubectl-<plugin-name>
```

So for your command:
```
kubectl tenant approve <tenantrequest>
```

👉 The binary must be named:
```
kubectl-tenant
```

## Build the Binary

Create the executable:
```
go build -o kubectl-tenant
```

## Move It to Your PATH

You need to place it somewhere kubectl can find it.

**Option A (recommended):**
```
mv kubectl-tenant /usr/local/bin/
```

**Option B (user-only):**
```
mv kubectl-tenant ~/.local/bin/
```

Make sure it’s executable:
```
chmod +x kubectl-tenant
```
