package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	tenantResourceName = "tenant-xr"

	PhaseValidating      = "Validating"
	PhasePendingApproval = "PendingApproval"
	PhaseProvisioning    = "Provisioning"
	PhaseReady           = "Ready"
	PhaseFailed          = "Failed"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	kube ctrlclient.Client
	pdns PDNSClient

	dnsBaseDomain string
}

func (f *Function) RunFunction(ctx context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {

	start := time.Now()

	f.log.Info("Running function", "tag", req.GetMeta().GetTag())

	// This is the object Crossplane expects the function to return.
	// It copies metadata from the request so Crossplane can correlate the response with the correct pipeline execution.
	// TTL says how long this response should remain (1 minute by default) valid before the function should be called again.
	rsp := response.To(req, response.DefaultTTL)

	// ---------------------------------------------------------------------
	// Read TenantRequest XR
	// ---------------------------------------------------------------------

	// Extract the Composite Resource being reconciled from the request, and stop the function if it cannot be retrieved.
	xr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get XR"))
		return rsp, nil
	}

	// xr.Resource is the unstructured Kubernetes object representing the XR.
	// Conceptually:
	// xr
	//  └── Resource
	//       ├── metadata
	//       ├── spec
	//       └── status
	name, _ := xr.Resource.GetString("spec.name")
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")
	displayName, _ := xr.Resource.GetString("spec.displayName")
	team, _ := xr.Resource.GetString("spec.owner.team")
	email, _ := xr.Resource.GetString("spec.owner.email")

	syncRepos, _ := xr.Resource.GetValue("spec.argocd.syncRepos")

	f.log.Info(
		"Reconciling tenant",
		"tenant", name,
		"dnsName", dnsName,
		"team", team,
	)

	// ---------------------------------------------------------------------
	// Validation (DO NOT fatal)
	// ---------------------------------------------------------------------

	_ = xr.Resource.SetValue("status.phase", PhaseValidating)

	if verr := f.validate(ctx, xr); verr != nil {
		f.log.Info("TenantRequest validation failed",
			"reason", verr.Reason,
			"message", verr.Message,
		)

		if verr.Retryable {
			_ = xr.Resource.SetValue("status.phase", PhaseValidating)
		} else {
			_ = xr.Resource.SetValue("status.phase", PhaseFailed)
		}

		response.ConditionFalse(rsp, "Valid", verr.Reason).
			WithMessage(verr.Message).
			TargetCompositeAndClaim()

		response.ConditionFalse(rsp, "Ready", "ValidationFailed").
			WithMessage("TenantRequest is not valid, provisioning is blocked").
			TargetCompositeAndClaim()

		xr.Resource.SetManagedFields(nil)
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	response.ConditionTrue(rsp, "Valid", "ValidationPassed").
		TargetCompositeAndClaim()

	// ---------------------------------------------------------------------
	// Approval gate
	// ---------------------------------------------------------------------
	// If the TenantRequest has not been approved yet, reconciliation pauses here.
	// The resource phase is set to PendingApproval and the Approved/Ready
	// conditions are marked as false with the reason WaitingForApproval.
	// No further processing happens until approval is granted.

	if !isApproved(xr) {
		f.log.Info("TenantRequest waiting for approval", "name", name)

		_ = xr.Resource.SetValue("status.phase", PhasePendingApproval)

		// Mark the request as not approved yet.
		response.ConditionFalse(rsp, "Approved", "WaitingForApproval").
			TargetCompositeAndClaim()

		// The resource cannot report Ready while approval is pending.
		response.ConditionFalse(rsp, "Ready", "WaitingForApproval").
			TargetCompositeAndClaim()

		// Return the updated XR so the status changes are written back to Kubernetes.
		xr.Resource.SetManagedFields(nil)
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	// The approval gate has been satisfied; mark the request as approved.
	response.ConditionTrue(rsp, "Approved", "Approved").
		TargetCompositeAndClaim()

	// ---------------------------------------------------------------------
	// Observe composed resources
	// ---------------------------------------------------------------------
	// Observed (Reality): resources currently running in the cluster
	// Desired (Plan): resources the function says should exist
	//
	// First iteration:
	// 		observed = {}
	// 		desired  = { tenant-xr }
	observed, err := request.GetObservedComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	tenantReady := false

	// If the tenant resource already exists, check whether it reports Ready.
	if tenantRes, ok := observed[resource.Name(tenantResourceName)]; ok && tenantRes.Resource != nil {
		tenantReady = hasConditionTrue(tenantRes.Resource, "Ready")
	}

	// ---------------------------------------------------------------------
	// Desired composed resources
	// ---------------------------------------------------------------------
	// Retrieve the desired composed resources from the request so they
	// can be updated or added during reconciliation.
	// desired = {
	//   tenant-xr
	// }
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Create Tenant XR (only after Valid + Approved)
	// ---------------------------------------------------------------------

	tenant := composed.New()

	f.log.Info(
		"Ensuring tenant resource",
		"tenant", name,
	)

	// Declare the desired tenant resource.
	tenant.SetAPIVersion("idp.rezakara.demo/v1alpha1")
	tenant.SetKind("Tenant")
	tenant.SetName(name)

	if err := tenant.SetValue("spec",
		buildTenantSpec(name, dnsName, envPrefix, displayName, team, email, syncRepos),
	); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// Describe the desired composed resource returned to Crossplane.
	desiredTenant := &resource.DesiredComposed{
		Resource: tenant,
		Ready:    resource.ReadyFalse,
	}

	// Propagate readiness from the observed Tenant resource.
	if tenantReady {
		desiredTenant.Ready = resource.ReadyTrue
	}

	desired[resource.Name(tenantResourceName)] = desiredTenant

	// ---------------------------------------------------------------------
	// Update phase based on tenant readiness
	// ---------------------------------------------------------------------

	// If the composed Tenant resource is ready, mark the XR as Ready and
	// update the phase accordingly.
	if tenantReady {
		_ = xr.Resource.SetValue("status.phase", PhaseReady)
		_ = xr.Resource.SetValue("status.tenantName", name)

		response.ConditionTrue(rsp, "Ready", "TenantReady").
			TargetCompositeAndClaim()
	} else {
		// Otherwise the Tenant is still being created or configured, so
		// keep the XR in the Provisioning phase and report Ready=false.
		_ = xr.Resource.SetValue("status.phase", PhaseProvisioning)
		_ = xr.Resource.SetValue("status.tenantName", name)

		response.ConditionFalse(rsp, "Ready", "TenantProvisioning").
			TargetCompositeAndClaim()
	}

	xr.Resource.SetManagedFields(nil)

	_ = response.SetDesiredCompositeResource(rsp, xr)

	// ---------------------------------------------------------------------
	// Return desired graph
	// ---------------------------------------------------------------------

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	f.log.Info(
		"Reconciliation finished",
		"tenant", name,
		"duration", time.Since(start),
	)

	return rsp, nil
}

// ---------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------

type ValidationError struct {
	Reason    string
	Message   string
	Retryable bool
}

func (f *Function) validate(ctx context.Context, xr *resource.Composite) *ValidationError {

	// -----------------------------------------------------------------
	// 1. Required fields
	// -----------------------------------------------------------------
	if err := validateRequiredFields(xr); err != nil {
		return err
	}

	name, _ := xr.Resource.GetString("spec.name")
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")

	// -----------------------------------------------------------------
	// 2. Cluster uniqueness: Tenant
	// -----------------------------------------------------------------
	if err := f.checkTenantNameUnique(ctx, name); err != nil {
		return &ValidationError{
			Reason:    "TenantNameTaken",
			Message:   err.Error(),
			Retryable: false,
		}
	}

	// -----------------------------------------------------------------
	// 3. Cluster uniqueness: DNS
	// -----------------------------------------------------------------
	if err := f.checkDNSNameUnique(ctx, dnsName); err != nil {
		return &ValidationError{
			Reason:    "DnsNameTaken",
			Message:   err.Error(),
			Retryable: false,
		}
	}

	// -----------------------------------------------------------------
	// 4. PowerDNS check
	// -----------------------------------------------------------------
	fqdn := buildFQDN(dnsName, envPrefix, f.dnsBaseDomain)

	result, err := f.pdns.CheckDNSAvailable(ctx, fqdn)
	if err != nil {
		return &ValidationError{
			Reason:    "DnsCheckFailed",
			Message:   err.Error(),
			Retryable: isRetryable(err),
		}
	}

	if !result.Available {
		return &ValidationError{
			Reason:    "DnsNameTaken",
			Message:   result.Message,
			Retryable: false,
		}
	}

	return nil
}

func validateRequiredFields(xr *resource.Composite) *ValidationError {

	name, _ := xr.Resource.GetString("spec.name")
	if name == "" {
		return &ValidationError{"InvalidSpec", "spec.name is required", false}
	}

	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	if dnsName == "" {
		return &ValidationError{"InvalidSpec", "spec.dnsName is required", false}
	}

	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")
	if envPrefix == "" {
		return &ValidationError{"InvalidSpec", "spec.environmentPrefix is required", false}
	}

	team, _ := xr.Resource.GetString("spec.owner.team")
	if team == "" {
		return &ValidationError{"InvalidSpec", "spec.owner.team is required", false}
	}

	repos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil || repos == nil {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos is required", false}
	}

	reposList, ok := repos.([]any)
	if !ok || len(reposList) == 0 {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos must not be empty", false}
	}

	return nil
}

func (f *Function) checkTenantNameUnique(ctx context.Context, name string) error {

	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "TenantList",
	})

	if err := f.kube.List(ctx, list); err != nil {
		return err
	}

	for _, item := range list.Items {
		if item.GetName() == name {
			return fmt.Errorf("tenant '%s' already exists", name)
		}
	}

	return nil
}

func (f *Function) checkDNSNameUnique(ctx context.Context, dns string) error {

	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "TenantList",
	})

	if err := f.kube.List(ctx, list); err != nil {
		return err
	}

	for _, item := range list.Items {
		val, _, _ := unstructured.NestedString(item.Object, "spec", "dnsName")
		if val == dns {
			return fmt.Errorf("dns '%s' already in use", dns)
		}
	}

	return nil
}

func buildFQDN(dnsName, env, base string) string {
	base = strings.TrimSuffix(base, ".")
	return fmt.Sprintf("%s.%s.%s.", dnsName, env, base)
}

func isRetryable(err error) bool {
	return strings.Contains(err.Error(), "timeout") ||
		strings.Contains(err.Error(), "connection") ||
		strings.Contains(err.Error(), "refused")
}

// ---------------------------------------------------------------------
// Build Tenant spec
// ---------------------------------------------------------------------
// buildTenantSpec constructs the spec map for the Tenant resource.
func buildTenantSpec(
	name string,
	dnsName string,
	env string,
	displayName string,
	team string,
	email string,
	repos any,
) map[string]any {

	if displayName == "" {
		displayName = name
	}

	spec := map[string]any{
		"name":              name,
		"dnsName":           dnsName,
		"environmentPrefix": env,
		"displayName":       displayName,
		"owner": map[string]any{
			"team": team,
		},
		"argocd": map[string]any{
			"syncRepos": repos,
		},
	}

	if email != "" {
		spec["owner"].(map[string]any)["email"] = email
	}

	return spec
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------
// isApproved checks whether the Composite Resource has been approved
// by looking for an Approved=True condition in status.conditions.
// If the condition is not present or the status cannot be read,
// the request is considered not approved.
func isApproved(xr *resource.Composite) bool {
	conditions, err := xr.Resource.GetValue("status.conditions")
	if err != nil {
		return false
	}

	conds, ok := conditions.([]any)
	if !ok {
		return false
	}

	for _, c := range conds {
		cond, ok := c.(map[string]any)
		if !ok {
			continue
		}

		if cond["type"] == "Approved" && cond["status"] == "True" {
			return true
		}
	}

	return false
}

// hasConditionTrue checks whether the resource reports a condition of the
// given type with status=True in status.conditions. If the conditions field
// is missing or cannot be parsed, the function returns false.
func hasConditionTrue(res interface {
	GetValue(string) (any, error)
}, conditionType string) bool {
	conditions, err := res.GetValue("status.conditions")
	if err != nil {
		return false
	}

	conds, ok := conditions.([]any)
	if !ok {
		return false
	}

	for _, c := range conds {
		cond, ok := c.(map[string]any)
		if !ok {
			continue
		}

		if cond["type"] == conditionType && cond["status"] == "True" {
			return true
		}
	}

	return false
}
