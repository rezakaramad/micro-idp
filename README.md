<p align="center" width="100%">
    <img width="24%" src="./logo.png">
</p>
<p align="center" >
  A paved road to Kubernetes for developers.
</p>
<p align="center" >
  <img src="https://img.shields.io/badge/internal%20developer%20platform-IDP-2F855A?style=flat" />
  <img src="https://img.shields.io/badge/kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white" />
  <img src="https://img.shields.io/badge/gitops-argoCD-orange?style=flat" />
  <img src="https://img.shields.io/badge/crossplane-326CE5?style=flat&logo=crossplane&logoColor=white" />
  <img src="https://img.shields.io/badge/helm-0F1689?style=flat&logo=helm&logoColor=white" />
  <img src="https://img.shields.io/badge/shell%20scripting-bash-4EAA25?style=flat&logo=gnubash&logoColor=white" />
</p>

## 🚀 Getting started

Make sure [task](https://taskfile.dev/docs/installation) is installed on your local machine.

Clone the repository:
```
git clone git@github.com:rezakaramad/kubepave.git && cd kubepave
```
Check dependencies:

```bash
task check
```

Start clusters only:

```bash
task start
```

Bootstrap everything:

```bash
task up
```

Load the Argo CD admin password and Vault token into your shell:

```bash
source .platform.env
```

Copy secrets to your clipboard:

```bash
printf %s "$VAULT_ROOT_TOKEN" | xclip -selection clipboard
```
```bash
printf %s "$ARGOCD_ADMIN_PASSWORD" | xclip -selection clipboard
```

## 🧹 Destroy everything

```bash
task down
```
---

## Why Task

Task lets you define:
- which scripts run
- in what order
- with which variables
All in a clean and readable way — nothing fancy.

Compared to a **Makefile**, Task feels simpler and more human-friendly.  
Make is extremely powerful, but its syntax and behavior were originally designed for build systems rather than general project automation.

Tools like **Just** take a similar approach to improving the developer experience.  
A **Justfile** is great for running small command recipes and replacing simple Makefiles, but it focuses more on being a command runner than a task orchestrator.

**Task**, on the other hand, provides features that fit this project better:
- explicit task dependencies
- built-in parallel execution
- environment and variable handling
- cross-platform behavior

So while **Make**, **Just**, and **Task** all solve similar problems, Task strikes a nice balance between simplicity and automation for this repository.

But there’s no perfect tool for everyone — and this is no exception.

## Where does it run?

It started with Minikube for local development.
Later it grew to support other environments too (Kind, maybe AWS/GCP in the future).

For local setup, plain **shell scripts** work best — they run everywhere without extra dependencies.

So the repo uses a few scripts to:
- start clusters
- install components
- wire everything together

to get you up and running quickly.

In the future, additional approaches may be added for cloud environments.


## Minikube Driver
### Why KVM instead of Docker?

This setup runs multiple Kubernetes clusters (`management` and `workload`) that need to talk to each other reliably.

The Docker driver is easy to start with, but each Minikube profile runs in its own isolated Docker network. This makes cross-cluster communication difficult and often requires extra workarounds like port forwarding, tunnels, or custom routing.

The **KVM** (`kvm2`) driver runs each cluster as a small virtual machine on the same shared network. This gives us:
- simple, direct networking between clusters
- predictable IP addresses
- no Docker NAT or hidden firewall rules
- behavior closer to real infrastructure
- fewer hacks and special setup

👉 To learn how to install KVM follow the [installation guide](https://help.ubuntu.com/community/KVM/Installation).

# Repository Structure

| Component | Location | Description |
|-----------|----------|-------------|
| **Argo CD** | `argocd-applications/` | Contains all Argo CD resources. |
| **Helm Charts** | `charts/` | Contains Helm charts used by the platform. We depend on official upstream charts and compose them as dependencies. |
| **Bootstrap (Minikube)** | `src/bootstrap/minikube/` | Resources and scripts required to spin up the Minikube edition of the platform. |
| **Crossplane Functions** | `src/crossplane/` | Contains Crossplane functions used by the platform. |
| **kubectl Plugins** | `src/kubectl-plugins/` | Custom kubectl plugins that should be installed in `/usr/local/bin`. |

Made with 🤓, 🐧 and 🍷.
