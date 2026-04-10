<p align="center" width="100%">
<img width="22%" src="./logo.png">
</p>

<h1 align="center">
{{ .Values.tenant.name | replace "-" " " | title }} Deployment
</h1>

<p align="center">
Declarative configuration for this tenant environment.<br/>
Managed with <b>Crossplane</b> • Reconciled by <b>Argo CD</b> • Powered by <b>GitOps</b>
</p>

<p align="center">
<img src="https://img.shields.io/badge/gitops-argoCD-orange?style=flat&logo=argo" />
<img src="https://img.shields.io/badge/crossplane-managed-6B46C1?style=flat&logo=kubernetes&logoColor=white" />
<img src="https://img.shields.io/badge/kubernetes-native-326CE5?style=flat&logo=kubernetes&logoColor=white" />
<img src="https://img.shields.io/badge/tenant-environment-blue?style=flat" />
</p>

> ⚠️ **This file is automatically managed by Crossplane. Do not edit manually.**

> It follows a GitOps workflow where changes are continuously reconciled to the cluster by Argo CD.

## 🎯 Purpose

Define and manage workloads declaratively.
Any change pushed to this repository is automatically applied to the cluster through Argo CD.

## 📁 Structure
```bash
.
└── apps
    └── <AppName>
        ├── dev
        ├── test
        └── prod
```

Empty directories are tracked using `.gitkeep` files.

---

## 🚀 Add a new application

To add a new application, create a directory under `apps/` and add one folder per environment (`dev`, `test`, `prod`). Place your Kubernetes manifests inside the appropriate environment folders, then commit and push.

### 1. Create a directory

```bash
mkdir -p apps/<AppName>/{dev,test,prod}
```

Example:

```bash
.
└── apps
    └── payment
        ├── dev
        ├── prod
        └── test
```

### 2. Add your Kubernetes manifests

Place your YAML files inside the environment folder:

```bash
.
└── apps
    └── payment
        └── dev
            ├── deployment.yaml
            ├── service.yaml
            └── ...
```

### 3. Commit & push

```bash
git add .
git commit -m "feat: add payment service"
git push
```

Argo CD will automatically detect the changes and deploy them to the cluster.

✨ No manual `kubectl` required. 

## 💡 Notes

- This repository is the source of truth for this environment
- Changes are applied automatically by Argo CD
- No manual kubectl or CI/CD pipelines required

---

## 🌐 DNS

| Environment     | Hostname                                           |
|-----------------|----------------------------------------------------|
| Workload `wl`   | `*.{{ .Values.tenant.dnsName }}.wl.rezakara.demo` |

---

## 🚦 HTTPRoute / Gateway
This is how tenants need to create their HTTPRoute resources, either directly or through an abstraction provided by DevEx:

```yaml
parentRefs:
    - group: gateway.networking.k8s.io
        kind: Gateway
        name: "{{ .Values.tenant.name }}"
        namespace: platform-system
        sectionName: https
```

Made with 🤓, 🐧 and 🍷.
