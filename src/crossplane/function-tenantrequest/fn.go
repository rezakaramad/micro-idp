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

// Function is this service's implementation of the Crossplane Function gRPC server.
// The important requirement is not the struct name itself, but that it provides
// a RunFunction(...) method with the expected signature so Crossplane can call it.

// Embedding UnimplementedFunctionRunnerServiceServer helps satisfy the generated
// gRPC service interface and is the normal Go pattern used by the SDK examples.
// The remaining fields are this function's own dependencies, such as logging,
// Kubernetes access, PowerDNS access, and local config needed by RunFunction(...).
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	kube ctrlclient.Client
	pdns PDNSClient

	dnsBaseDomain string
}

// RunFunction is the method Crossplane calls to execute this function.
// It takes the incoming request, performs the function's logic,
// and returns the response Crossplane should use next.
func (f *Function) RunFunction(ctx context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {

	// Record when this reconciliation started so we can measure and log
	// the total time taken at the end with time.Since(start).
	start := time.Now()

	// Log start of function execution with a request tag for tracing this run.
	f.log.Info("Running function", "tag", req.GetMeta().GetTag())

	// This is the object Crossplane expects the function to return.
	// It copies metadata from the request so Crossplane can correlate the response with the correct pipeline execution.
	// TTL says how long this response should remain (1 minute by default) valid before the function should be called again.
	rsp := response.To(req, response.DefaultTTL)

	// ---------------------------------------------------------------------
	// Read TenantRequest XR
	// ---------------------------------------------------------------------
	// Extract the Composite Resource being reconciled from the request, and stop the function if it cannot be retrieved.
	// When Crossplane calls your function, it sends a request object (req) that contains:
	// everything this function needs to understand the current state of the system
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
	name, err := xr.Resource.GetString("spec.name")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.name"))
		return rsp, nil
	}

	dnsName, err := xr.Resource.GetString("spec.dnsName")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.dnsName"))
		return rsp, nil
	}

	envPrefix, err := xr.Resource.GetString("spec.environmentPrefix")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.environmentPrefix"))
		return rsp, nil
	}

	displayName, err := xr.Resource.GetString("spec.displayName")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.displayName"))
		return rsp, nil
	}

	team, err := xr.Resource.GetString("spec.owner.team")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.owner.team"))
		return rsp, nil
	}

	email, err := xr.Resource.GetString("spec.owner.email")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.owner.email"))
		return rsp, nil
	}

	syncRepos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.argocd.syncRepos"))
		return rsp, nil
	}

	f.log.Info(
		"Reconciling tenant",
		"tenant", name,
		"dnsName", dnsName,
		"team", team,
	)

	// ---------------------------------------------------------------------
	// Validation (DO NOT fatal)
	// ---------------------------------------------------------------------
	// Before doing any work, validate the request to ensure it is well-formed and can be processed.
	// Function State Machine
	// States are tracked in status.phase and conditions. The main states are:
	// - Validating
	// - PendingApproval
	// - Provisioning
	// - Ready
	// - Failed
	//
	// Flow Overview
	// START
	//   ↓
	// Validating
	//   ↓ (validation fails, non-retryable)
	// Failed
	//   ↓ (validation fails, retryable)
	// Validating (retry)
	//   ↓ (validation passes)
	// PendingApproval
	//   ↓ (not approved)
	// PendingApproval (loop)
	//   ↓ (approved)
	// Provisioning
	//   ↓ (tenant not ready yet)
	// Provisioning (loop)
	//   ↓ (tenant ready)
	// Ready
	_ = xr.Resource.SetValue("status.phase", PhaseValidating)

	// Call the Function's validation logic (defined below) to validate the XR.
	if validationError := f.validate(ctx, xr); validationError != nil {
		f.log.Info("TenantRequest validation failed",
			"reason", validationError.Reason,
			"message", validationError.Message,
		)

		// Retryability is decided explicitly when returning ValidationError:
		// system/temporary errors are marked retryable,
		// while user/config errors are marked non-retryable.
		if validationError.Retryable {
			_ = xr.Resource.SetValue("status.phase", PhaseValidating)
		} else {
			_ = xr.Resource.SetValue("status.phase", PhaseFailed)
		}

		// Set Valid=false with reason/message on the XR and its claim.
		// This is what the user will see when they kubectl describe the XR or claim, and it should explain why validation failed.
		// status:
		//   conditions:
		//     - lastTransitionTime: "2026-04-02T19:57:07Z"
		//       message: dns 'pay' already in use
		//       reason: DnsNameTaken
		//       status: "False"
		//       type: Valid
		response.ConditionFalse(rsp, "Valid", validationError.Reason).
			WithMessage(validationError.Message).
			TargetCompositeAndClaim()

		// Also mark Ready=false because invalid input blocks provisioning,
		// even though the specific issue is captured by the Valid condition.
		response.ConditionFalse(rsp, "Ready", "ValidationFailed").
			WithMessage("TenantRequest is not valid, provisioning is blocked").
			TargetCompositeAndClaim()

		// Remove Kubernetes internal metadata and return the updated XR
		// so Crossplane applies the new status/conditions.
		xr.Resource.SetManagedFields(nil)

		// Return the updated XR as desired state:
		// observed = what currently exists
		// desired = what should exist
		// Apply these updates to the XR so the new status and conditions are written back to Kubernetes.
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	// Mark the resource as valid (Valid=true) after successful validation
	// and apply this condition to both the Composite Resource and its claim.
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

		// status:
		//   phase: PendingApproval
		_ = xr.Resource.SetValue("status.phase", PhasePendingApproval)

		// Mark the request as not approved yet.
		// status:
		//   conditions:
		//   - lastTransitionTime: "2026-04-03T22:26:14Z"
		//     reason: WaitingForApproval
		//     status: "False"
		//     type: Approved
		response.ConditionFalse(rsp, "Approved", "WaitingForApproval").
			TargetCompositeAndClaim()

		// The resource cannot report Ready while approval is pending.
		// Note: Ready is also managed by Crossplane and may be overridden.
		// This is informational; use Approved/phase for actual control logic.
		response.ConditionFalse(rsp, "Ready", "WaitingForApproval").
			TargetCompositeAndClaim()

		// Remove Kubernetes internal metadata and return the updated XR
		// so Crossplane applies the new status/conditions.
		xr.Resource.SetManagedFields(nil)

		// Apply these updates to the XR so the new status and conditions are written back to Kubernetes.
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	// The approval gate has been satisfied; mark the request as approved.
	response.ConditionTrue(rsp, "Approved", "Approved").
		TargetCompositeAndClaim()

	// Reconciliation loop:
	// 1. Read observed state (what exists)
	// 2. Build desired state (what should exist)
	// 3. Return it so Crossplane reconciles the difference

	// ---------------------------------------------------------------------
	// Observe composed resources
	// ---------------------------------------------------------------------
	// Observed (Reality): resources currently running in the cluster
	// Desired (Plan): resources the function says should exist
	// First iteration:
	// 		observed = {}
	// 		desired  = { tenant-xr }
	// Read current cluster state (observed) and current plan (desired),
	// then use them to decide what should be updated in the desired state.
	// req is sent by Crossplane when it calls your function
	// What is inside req (simplified)
	// req
	// ├── observed  (REAL cluster state)
	// ├── desired   (planned state so far)
	// └── meta      (execution info)

	// From the request Crossplane sent me, extract the composed resources that currently exist, and give me either the result or an error.”
	// GetObservedComposedResources
	// Get = extract / read
	// Observed = what currently exists
	// ComposedResources = child resources created by the composition
	// So this function means:
	// “Read the currently existing composed resources (in my case, the Tenant resource) from the function request”
	observed, err := request.GetObservedComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// Assume nothing is ready until proven otherwise
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
// Validation has two phases:
// 1. Pre-provision validation
//    -> before Tenant exists
// 2. Post-provision validation
//    -> after Tenant already exists

type ValidationError struct {
	Reason    string
	Message   string
	Retryable bool
}

func (f *Function) validate(ctx context.Context, xr *resource.Composite) *ValidationError {

	// -----------------------------------------------------------------
	// 1. Required fields
	//    Before doing anything fancy, make sure the required input exists.
	// -----------------------------------------------------------------
	if err := validateRequiredFields(xr); err != nil {
		return err
	}

	// Gets the Kubernetes name of the XR itself (e.g. tenantrequest-sample-12345) so we can use it for ownership detection and uniqueness checks.
	requestName := xr.Resource.GetName()

	name, _ := xr.Resource.GetString("spec.name")
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")

	// Detect if tenant already exists and is owned by this request
	// Does a Tenant already exist that belongs to this XR?
	ownedTenant, err := f.getOwnedTenant(ctx, requestName)
	if err != nil {
		return &ValidationError{"ValidationError", err.Error(), true}
	}

	// Is there already a Tenant in the cluster owned by this XR?
	// If no Tenant is found for this XR, we are in pre-provision phase.
	// If a Tenant exists, we are in post-provision phase.
	isPostProvision := ownedTenant != nil

	// -----------------------------
	// Phase 1: Pre-provision
	// -----------------------------
	if !isPostProvision {

		// No other Tenant should already have this name
		if err := f.checkTenantNameUnique(ctx, requestName, name); err != nil {
			return &ValidationError{"TenantNameTaken", err.Error(), false}
		}

		// No other Tenant should already be using this DNS name
		if err := f.checkDNSNameUnique(ctx, requestName, dnsName); err != nil {
			return &ValidationError{"DnsNameTaken", err.Error(), false}
		}

		// This combines pieces like: dnsName, environmentPrefix, and base domain into something like: foo.dev.rezakara.demo.
		fqdn := buildFQDN(dnsName, envPrefix, f.dnsBaseDomain)

		// This asks PowerDNS: “Does this DNS already exist?”
		result, err := f.pdns.CheckDNSAvailable(ctx, fqdn)
		if err != nil {
			return &ValidationError{"DnsCheckFailed", err.Error(), isRetryable(err)}
		}

		if !result.Available {
			return &ValidationError{"DnsNameTaken", result.Message, false}
		}

		return nil
	}

	// ----------------------------------------------------
	// Phase 2: Post-provision
	// ----------------------------------------------------
	// Once the tenant already exists, we are no longer asking "is this name unique?" or "is this DNS available?"
	// because those questions are only relevant at creation time.
	// Validate consistency only

	// Immutable fields: name and dnsName.
	// If the existing Kubernetes Tenant name does not match the XR spec anymore, that is drift and should be rejected.
	if ownedTenant.GetName() != name {
		return &ValidationError{"DriftDetected", "tenant name mismatch", false}
	}

	// If the existing Tenant name does not match the XR spec anymore, that is drift and should be rejected.
	existingSpecName, _, _ := unstructured.NestedString(ownedTenant.Object, "spec", "name")
	if existingSpecName != name {
		return &ValidationError{"DriftDetected", "spec.name mismatch", false}
	}

	// If the existing Tenant DNS name does not match the XR spec anymore, that is drift and should be rejected.
	existingDNS, _, _ := unstructured.NestedString(ownedTenant.Object, "spec", "dnsName")
	if existingDNS != dnsName {
		return &ValidationError{"DriftDetected", "dns mismatch", false}
	}

	return nil
}

// ---------------------------------------------------------------------
// Ownership detection
// ---------------------------------------------------------------------
func (f *Function) getOwnedTenant(ctx context.Context, requestName string) (*unstructured.Unstructured, error) {
	// In Kubernetes, if you have "kind: Tenant", Kubernetes automatically creates a corresponding "kind: TenantList" that represents a list of those objects.
	// To find the Tenant that belongs to this XR, we can list all Tenants and look for the one with a label that matches our XR name.
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "TenantList",
	})

	// Query the Kubernetes API to list all Tenant resources (TenantList) into `list`.
	// If the API call fails, return the error since we cannot proceed without cluster state.
	if err := f.kube.List(ctx, list); err != nil {
		return nil, err
	}

	// Find the Tenant resource owned by this XR by matching the
	// crossplane.io/composite label to the XR name.
	for _, item := range list.Items {
		if item.GetLabels()["crossplane.io/composite"] == requestName {
			return &item, nil
		}
	}

	return nil, nil
}

func validateRequiredFields(xr *resource.Composite) *ValidationError {
	// Check that 'name' is present in the XR spec, and return a ValidationError if any are missing.
	name, _ := xr.Resource.GetString("spec.name")
	if name == "" {
		return &ValidationError{"InvalidSpec", "spec.name is required", false}
	}

	// Check that 'dnsName' is present in the XR spec, and return a ValidationError if any are missing.
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	if dnsName == "" {
		return &ValidationError{"InvalidSpec", "spec.dnsName is required", false}
	}

	// Check that 'envPrefix' is present in the XR spec, and return a ValidationError if any are missing.
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")
	if envPrefix == "" {
		return &ValidationError{"InvalidSpec", "spec.environmentPrefix is required", false}
	}

	// Check that 'team' is present in the XR spec, and return a ValidationError if any are missing.
	team, _ := xr.Resource.GetString("spec.owner.team")
	if team == "" {
		return &ValidationError{"InvalidSpec", "spec.owner.team is required", false}
	}

	// Check that 'repos' is present in the XR spec, and return a ValidationError if any are missing.
	repos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil || repos == nil {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos is required", false}
	}

	// Check that 'repos' is a non-empty list, and return a ValidationError if it is not.
	reposList, ok := repos.([]any)
	if !ok || len(reposList) == 0 {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos must not be empty", false}
	}

	return nil
}

// ---------------------------------------------------------------------
// Updated uniqueness checks
// ---------------------------------------------------------------------
func (f *Function) checkTenantNameUnique(ctx context.Context, requestName, name string) error {
	// In Kubernetes, if you have "kind: Tenant", Kubernetes automatically creates a corresponding "kind: TenantList" that represents a list of those objects.
	// To find the Tenant that belongs to this XR, we can list all Tenants and look for the one with a label that matches our XR name.
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "TenantList",
	})

	// Query the Kubernetes API to list all Tenant resources (TenantList) into `list`.
	// If the API call fails, return the error since we cannot proceed without cluster state.
	if err := f.kube.List(ctx, list); err != nil {
		return err
	}

	// Find the Tenant resource owned by this XR by matching the
	// crossplane.io/composite label to the XR name.
	// For each Tenant in the cluster:
	// If it belongs to this XR → validate consistency (name and spec.name must match)
	// If it belongs to another XR → enforce uniqueness (name and spec.name must not match)
	for _, item := range list.Items {

		itemName := item.GetName()
		specName, _, _ := unstructured.NestedString(item.Object, "spec", "name")
		owner := item.GetLabels()["crossplane.io/composite"]

		// If this Tenant belongs to this XR → validate consistency
		if owner == requestName {

			if itemName != name {
				return fmt.Errorf("owned Tenant metadata.name mismatch: expected %s, got %s", name, itemName)
			}

			if specName != name {
				return fmt.Errorf("owned Tenant spec.name mismatch: expected %s, got %s", name, specName)
			}

			continue
		}

		// If it belongs to another XR → enforce uniqueness
		if itemName == name {
			return fmt.Errorf("tenant metadata.name '%s' already exists", name)
		}

		if specName == name {
			return fmt.Errorf("tenant spec.name '%s' already exists", name)
		}
	}

	return nil
}

func (f *Function) checkDNSNameUnique(ctx context.Context, requestName, dns string) error {
	// In Kubernetes, if you have "kind: Tenant", Kubernetes automatically creates a corresponding "kind: TenantList" that represents a list of those objects.
	// To find the Tenant that belongs to this XR, we can list all Tenants and look for the one with a label that matches our XR name.
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "TenantList",
	})

	// Query the Kubernetes API to list all Tenant resources (TenantList) into `list`.
	// If the API call fails, return the error since we cannot proceed without cluster state.
	if err := f.kube.List(ctx, list); err != nil {
		return err
	}

	// For each Tenant in the cluster:
	// If it belongs to this XR → skip (we allow the same DNS in this case because it is the same tenant)
	// If it belongs to another XR → enforce uniqueness (dnsName must not match)
	for _, item := range list.Items {
		val, _, _ := unstructured.NestedString(item.Object, "spec", "dnsName")
		if val == dns {
			if item.GetLabels()["crossplane.io/composite"] == requestName {
				continue
			}
			return fmt.Errorf("dns '%s' already in use", dns)
		}
	}

	return nil
}

// buildFQDN combines dnsName, environmentPrefix, and base domain into a fully qualified domain name like: foo.dev.rezakara.demo.
func buildFQDN(dnsName, env, base string) string {
	base = strings.TrimSuffix(base, ".")
	return fmt.Sprintf("%s.%s.%s.", dnsName, env, base)
}

// isRetryable determines whether an error is retryable based on its message content.
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
