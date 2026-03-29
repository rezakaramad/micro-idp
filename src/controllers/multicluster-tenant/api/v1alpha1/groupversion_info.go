// Package v1alpha1 contains API Schema definitions for the m.idp v1alpha1 API group.
// This defines “what API group/version do my types belong to,
// and how do I register them into a Scheme?”

// +kubebuilder:object:generate=true
// +groupName=m.idp.rezakara.demo
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	// The namespace of API
	// Kubernetes identifies objects using: (apiVersion, kind)
	GroupVersion = schema.GroupVersion{
		Group:   "m.idp.rezakara.demo",
		Version: "v1alpha1",
	}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	// When you later do:
	// 		SchemeBuilder.Register(&Tenant{}, &TenantList{})
	// It prepares something like:
	//   scheme.AddKnownTypes(
	//     "m.idp.rezakara.demo/v1alpha1",
	//     Tenant,
	//     TenantList
	//   )
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
