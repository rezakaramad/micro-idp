package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status
// Tenant is the Schema for the tenants API
// Lifecycle of this object: user creates Tenant → K8s stores it → controller watches it → controller reads Spec → controller updates Status.
type Tenant struct {
	// What kind of object this is
	// Basically contains
	// apiVersion: m.idp.rezakaramad.local/v1alpha1
	// kind: Tenant
	metav1.TypeMeta `json:",inline"`
	// Identity + metadata
	// Contains
	// Contains:
	// metadata:
	//   name:
	//   labels:
	//   annotations:
	//   finalizers:
	//   generation:
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// Desired state (user input)
	Spec TenantSpec `json:"spec,omitempty"`
	// Observed state (controller output)
	Status TenantStatus `json:"status,omitempty"`
}

// TenantSpec defines the desired state of Tenant
type TenantSpec struct {
	// Reserved for future configuration.
	// Tenant identity comes from metadata.name.
}

// TenantStatus defines the observed state of Tenant.
type TenantStatus struct {
	// Conditions represent the latest available observations of the Tenant's state.
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// TenantList contains a list of Tenant
type TenantList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Tenant `json:"items"`
}

// Why is TenantList a root object?
// Because K8s API needs it. K8s supports two types of requests:
// 1. Get one object → 'GET /apis/.../tenants/team-a'
// 2. List objects → 'GET /apis/.../tenants'
// TenantList must a root object because it appears at the API boundary.

// Registrer a new type called Tenant
func init() {
	SchemeBuilder.Register(&Tenant{}, &TenantList{})
}

// 'init' function is a special Go function running automatically when the package is imported - we never call it manually.
