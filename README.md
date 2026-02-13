<html>
<p align="center" width="100%">
    <img width="24%" src="./logo.png">
</p>
<p align="center" >
  A micro Internal Developer Platform for local Kubernetes.
</p>
<p align="center" >
  <img src="https://img.shields.io/badge/internal%20developer%20platform-IDP-2F855A?style=flat" />
  <img src="https://img.shields.io/badge/kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white" />
  <img src="https://img.shields.io/badge/gitops-argoCD-orange?style=flat" />
  <img src="https://img.shields.io/badge/helm-0F1689?style=flat&logo=helm&logoColor=white" />
  <img src="https://img.shields.io/badge/shell%20scripting-bash-4EAA25?style=flat&logo=gnubash&logoColor=white" />

</p>
</html>

# How-to
Everything needed to bootstrap this Micro IDP is automated using a **Taskfile**.

If you don't have Task installed, follow [this guide](https://taskfile.dev/docs/installation).

---

**Why Task**

Mostly curiosity 🙂 — but it turned out to be a great fit.
Task lets you define:
- which scripts run
- in what order
- with which variables
All in a clean and readable way.

Compared to a Makefile, Task feels simpler and more human-friendly.

The only downside is that you need to install the Task binary first.  
But there’s no perfect tool for everyone — and this is no exception.

**Where does it run?**
It started with Minikube for local development.
Later it grew to support other environments too (Kind, maybe AWS/GCP in the future).

For local setup, plain **shell scripts** work best — they run everywhere without extra dependencies.

So the repo just uses a few small scripts to:
- start clusters
- install components
- wire everything together

Nothing fancy. Just enough to get you up and running quickly.

In the future, additional approaches may be added for cloud environments.

Getting started

Just run:
```
task --dir minikube up
```
To have Argo CD admin password and Vault token in your terminal environment, run:
```
source .platform-creds.env
```
Use the below commands if you don't want to display the credential:
```
printf %s $VAULT_ROOT_TOKEN | xclip -selection clipboard
```
```
printf %s $ARGOCD_ADMIN_PASSWORD | xclip -selection clipboard
```
# 🧹 How to Destroy Everything
Just run:
```
task --dir minikube down
```
# Futher details

## Argo CD
In the `argocd-applications` directory you will find all the Argo CD resources.

## Minikube
In the `minikube` directory you will find everything you need to spin up the clusters using Minikube.

## Helm charts
All Helm charts in this repository live under `charts` directory.

We depend on the official upstream Helm charts and compose them as dependencies.  
Tenant-specific provisioning charts are located in `charts/tenants`.

Made with ❤️ and ✨.
