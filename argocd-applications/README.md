# argocd-applications

In Argo CD, a normal sync performs a patch (similar to `kubectl apply`).
This may fail if Kubernetes disallows modifying immutable or controller-managed fields.
Using **Replace + Force** makes Argo CD delete the existing resource and recreate it, bypassing patch restrictions.

This typically occurs during the bootstrap phase.