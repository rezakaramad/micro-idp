package main

import (
	"context"
	"fmt"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
)

const (
	tenantResourceName = "tenant-xr"

	PhasePendingApproval = "PendingApproval"
	PhaseProvisioning    = "Provisioning"
	PhaseReady           = "Ready"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger
}

func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {

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
	team, _ := xr.Resource.GetString("spec.owner.team")
	email, _ := xr.Resource.GetString("spec.owner.email")

	f.log.Info(
		"Reconciling tenant",
		"tenant", name,
		"dnsName", dnsName,
		"team", team,
	)

	if name == "" {
		response.Fatal(rsp, fmt.Errorf("spec.name is required"))
		return rsp, nil
	}

	// erros.Wrap creates a new error that contains the original error.
	syncRepos, err := xr.Resource.GetValue("spec.gitops.syncRepos")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "spec.gitops.syncRepos is required"))
		return rsp, nil
	}

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
	// Create Tenant XR
	// ---------------------------------------------------------------------

	tenant := composed.New()

	f.log.Info(
		"Ensuring tenant resource",
		"tenant", name,
	)

	// Declare the desired tenant resource.
	tenant.SetAPIVersion("idp.fluxdojo.local/v1alpha1")
	tenant.SetKind("Tenant")
	tenant.SetName(name)

	if err := tenant.SetValue("spec", buildTenantSpec(name, dnsName, envPrefix, team, email, syncRepos)); err != nil {
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

		response.ConditionTrue(rsp, "Ready", "TenantReady").
			TargetCompositeAndClaim()
	} else {
		// Otherwise the Tenant is still being created or configured, so
		// keep the XR in the Provisioning phase and report Ready=false.
		_ = xr.Resource.SetValue("status.phase", PhaseProvisioning)

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

// buildTenantSpec constructs the spec map for the Tenant resource.
func buildTenantSpec(
	name string,
	dnsName string,
	env string,
	team string,
	email string,
	repos any,
) map[string]any {
	spec := map[string]any{
		"name":              name,
		"dnsName":           dnsName,
		"environmentPrefix": env,
		"displayName":       name,
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
