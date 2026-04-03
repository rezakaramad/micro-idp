# Mapping `kubectl get pods` to Go (`ctrlclient`, `kubeClient`, `scheme`)

When you run:

```bash
kubectl get pods
```

you are asking Kubernetes:

> "Give me a list of Pod objects."

In Go, the same job is split into a few parts.

## Quick mapping

- `kubectl` → the command-line tool a human uses
- `ctrlclient` → the Go package used to create and work with a Kubernetes client
- `kubeClient` → the actual client object your code uses to talk to Kubernetes
- `cfg` → connection details for the Kubernetes cluster
- `scheme` → the list of Kubernetes object types the client understands, such as Pods and Services

### What each part does
#### `cfg`

```golang
cfg, err := ctrlconfig.GetConfig()
```

This loads the Kubernetes connection settings.

Think of it as:

> how to find and connect to the Kubernetes API server

This is similar to how kubectl reads your `kubeconfig`.

#### `scheme`
```golang
scheme := runtime.NewScheme()
utilruntime.Must(clientgoscheme.AddToScheme(scheme))
```

This creates and fills a registry of known Kubernetes object types.

Think of it as:

teaching the client what a Pod, Service, or Deployment looks like

Without the scheme, the client would not properly understand Kubernetes objects.

#### `ctrlclient`
```golang
ctrlclient.New(cfg, ctrlclient.Options{Scheme: scheme})
```

`ctrlclient` is the package that provides the logic for creating and using a Kubernetes client.

Think of it as:

the Go library that gives your program kubectl-like powers

#### `kubeClient`
```golang
kubeClient, err := ctrlclient.New(cfg, ctrlclient.Options{
    Scheme: scheme,
})
```

This is the actual client instance your code will use.

Think of it as:

your program’s own Kubernetes tool for reading and writing resources

### Closest Go equivalent of `kubectl get pods`
```golang
podList := &corev1.PodList{}
err := kubeClient.List(ctx, podList)
```

This is the closest match to:
```bash
kubectl get pods
```

### Side-by-side example
```bash
kubectl get pods
```

Go
```golang
cfg, _ := ctrlconfig.GetConfig()

scheme := runtime.NewScheme()
clientgoscheme.AddToScheme(scheme)

kubeClient, _ := ctrlclient.New(cfg, ctrlclient.Options{
    Scheme: scheme,
})

podList := &corev1.PodList{}
err := kubeClient.List(context.Background(), podList)
```