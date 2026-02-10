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

## How-to

In order to run 

# Futher details

## Argo CD
In the `argocd-applications` you will find all the Argo CD resources.

## Minikube
In the `minikube` you will find everything you need to spin up the clusters using Minikube.

## Helm charts
All Helm charts in this repository live under `charts`.

We depend on the official upstream Helm charts and compose them as dependencies.  
Tenant-specific provisioning charts are located in `kubernetes/charts/tenants`.

