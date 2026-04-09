package main

import (
	"context"
	"fmt"
	"time"

	"sigs.k8s.io/yaml"

	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
)

const (
	// Identifiers for composed resources
	entraGroupResourceName = "entra-group"
	gitopsResourceName     = "gitops-tenant"
	baselineResourceName   = "baseline-tenant"

	azureADProviderConfigName = "azuread"
	azureADOwnerObjectID      = "d98229ea-609e-4a61-bd1b-1bb092377571"

	PhaseProvisioning = "Provisioning"
	PhaseReady        = "Ready"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger
}

func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {

	start := time.Now()

	f.log.Info("Running function",
		"tag", req.GetMeta().GetTag())

	// This is the object Crossplane expects the function to return.
	// It copies metadata from the request so Crossplane can correlate the response with the correct pipeline execution.
	// TTL says how long this response should remain (1 minute by default) valid before the function should be called again.
	rsp := response.To(req, response.DefaultTTL)

	// ---------------------------------------------------------------------
	// Read Tenant XR
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
	team, _ := xr.Resource.GetString("spec.owner.team")
	email, _ := xr.Resource.GetString("spec.owner.email")
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")

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
	syncRepos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "invalid spec.argocd.syncRepos"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Desired resources
	// ---------------------------------------------------------------------
	// Get the current desired resource graph so this function can add or update
	// composed resources without overwriting results from earlier pipeline steps.
	// Example desired graph:
	// XR
	//  ├── entra-group
	//  ├── gitops-tenant
	//  └── baseline-tenant
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Observe composed resources
	// ---------------------------------------------------------------------
	// Observed (Reality): resources currently running in the cluster
	// Desired (Plan): resources the function says should exist
	//
	// First iteration:
	// 		observed = {}
	// 		desired  = { entra-group }
	// Second iteration:
	// 		observed = { entra-group }
	// 		desired  = { entra-group, gitops-tenant }
	// Third iteration
	//		observed = { entra-group, gitops-tenant }
	//		desired  = { entra-group, gitops-tenant, baseline-tenant }
	observed, err := request.GetObservedComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	f.log.Debug(
		"Loaded observed resources",
		"tenant", name,
		"count", len(observed),
	)

	var aadGroupID string

	// readiness state before we observe the resource status
	groupReady := resource.ReadyUnspecified
	gitopsReady := resource.ReadyUnspecified
	baselineReady := resource.ReadyUnspecified

	// ---------------------------------------------------------------------
	// Entra Group status
	// ---------------------------------------------------------------------
	// Check if the Entra group already exists in the observed resource graph
	if groupRes, ok := observed[resource.Name(entraGroupResourceName)]; ok && groupRes.Resource != nil {

		// If the resource exists in the observed graph
		// AND it has a valid Kubernetes object
		f.log.Info(
			"Observed Entra group",
			"tenant", name,
		)

		// Reads the Azure group ID
		aadGroupID, _ = groupRes.Resource.GetString("status.atProvider.objectId")

		if aadGroupID != "" {
			f.log.Info(
				"Entra group exists",
				"tenant", name,
				"aadGroupID", aadGroupID,
			)
		}

		// Check if the resource has a Ready condition with status True
		// If yes: mark the resource ready for Crossplane and log that it is ready
		// Most Kubernetes controllers expose readiness like this:
		//
		// status:
		//   conditions:
		//     - type: Ready
		//       status: "True"
		//       reason: Available
		if hasConditionTrue(groupRes.Resource, "Ready") {
			groupReady = resource.ReadyTrue

			f.log.Info(
				"Entra group ready",
				"tenant", name,
				"aadGroupID", aadGroupID,
			)
		}
	}

	// ---------------------------------------------------------------------
	// GitOps Application status
	// ---------------------------------------------------------------------

	if appRes, ok := observed[resource.Name(gitopsResourceName)]; ok && appRes.Resource != nil {

		// Check if the resource has a Ready condition with status True
		if isArgoAppHealthy(appRes.Resource) {
			gitopsReady = resource.ReadyTrue

			f.log.Info(
				"GitOps application healthy",
				"tenant", name,
			)
		}
	}

	// ---------------------------------------------------------------------
	// Baseline Application status
	// ---------------------------------------------------------------------

	if appRes, ok := observed[resource.Name(baselineResourceName)]; ok && appRes.Resource != nil {

		// Check if the resource has a Ready condition with status True
		if isArgoAppHealthy(appRes.Resource) {
			baselineReady = resource.ReadyTrue

			f.log.Info(
				"Baseline application healthy",
				"tenant", name,
			)
		}
	}

	// ---------------------------------------------------------------------
	// Create Entra Group
	// ---------------------------------------------------------------------
	// Declare the desired Entra Group resource for this tenant.
	// This does NOT create the resource directly. Instead, we construct the
	// desired state and add it to the desired resource graph. Crossplane will
	// compare this desired state with the observed state and create or update
	// the Azure AD group if needed during reconciliation.

	group := composed.New()

	f.log.Info(
		"Ensuring Entra group",
		"tenant", name,
	)

	group.SetAPIVersion("groups.azuread.m.upbound.io/v1beta1")
	group.SetKind("Group")
	group.SetName(fmt.Sprintf("entra-%s", name))
	group.SetNamespace("crossplane")

	err = group.SetValue("spec", map[string]any{
		"forProvider": map[string]any{
			"securityEnabled":       true,
			"mailEnabled":           false,
			"preventDuplicateNames": true,
			"owners": []any{
				azureADOwnerObjectID,
			},
			"displayName":  name,
			"mailNickname": name,
		},
		"providerConfigRef": map[string]any{
			"name": azureADProviderConfigName,
			"kind": "ProviderConfig",
		},
	})
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	desired[resource.Name(entraGroupResourceName)] = &resource.DesiredComposed{
		Resource: group,
		Ready:    groupReady,
	}

	// ---------------------------------------------------------------------
	// Wait until group exists
	// ---------------------------------------------------------------------
	// That block exists because your function must wait for the Entra group to exist
	// before creating dependent resources, and Crossplane accomplishes this through repeated reconciliation loops.

	if aadGroupID == "" {

		f.log.Info(
			"Waiting for Entra group",
			"tenant", name,
		)

		_ = xr.Resource.SetValue("status.phase", PhaseProvisioning)

		xr.Resource.SetManagedFields(nil)

		_ = response.SetDesiredCompositeResource(rsp, xr)
		_ = response.SetDesiredComposedResources(rsp, desired)

		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Update XR status
	// ---------------------------------------------------------------------
	// Before
	//
	// status:
	//   phase: Provisioning

	// After
	//
	// status:
	//   phase: Provisioning
	//   identity:
	//     aadGroupId: 12345678
	// Stores the Azure AD group ID in the Tenant XR status
	_ = xr.Resource.SetValue("status.identity.aadGroupId", aadGroupID)

	// ---------------------------------------------------------------------
	// GitOps Application
	// ---------------------------------------------------------------------
	// Now we finally have all the information required to configure the GitOps layer

	gitopsValues := map[string]any{
		"tenant": map[string]any{
			"name":    name,
			"dnsName": dnsName,
			"owner": map[string]any{
				"team":  team,
				"email": email,
			},
			"argocd": map[string]any{
				"aadGroupId": aadGroupID,
				"syncRepos":  syncRepos,
			},
		},
	}

	// Serialize the GitOps configuration into YAML for Helm values in the ArgoCD Application.
	valuesYaml, err := yaml.Marshal(gitopsValues)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	gitops := composed.New()

	if existing, ok := desired[resource.Name(gitopsResourceName)]; ok {
		gitops = existing.Resource
	}

	f.log.Info(
		"Ensuring GitOps application",
		"tenant", name,
	)

	// Declare the desired ArgoCD Application that installs the gitops-tenant Helm chart.
	// ArgoCD will reconcile this application and apply the chart
	// using the tenant-specific Helm values generated earlier.
	gitops.SetAPIVersion("argoproj.io/v1alpha1")
	gitops.SetKind("Application")
	gitops.SetName(fmt.Sprintf("gitops-%s", name))
	gitops.SetNamespace("argocd")

	err = gitops.SetValue("spec", map[string]any{
		"project": "default",
		"source": map[string]any{
			"repoURL":        "https://github.com/rezakaramad/kubepave.git",
			"targetRevision": "HEAD",
			"path":           "charts/gitops-tenant",
			"helm": map[string]any{
				"values": string(valuesYaml),
			},
		},
		"destination": map[string]any{
			"name":      "in-cluster",
			"namespace": "argocd",
		},
		"syncPolicy": map[string]any{
			"automated": map[string]any{
				"prune":    false,
				"selfHeal": true,
			},
		},
	})
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// Add the ArgoCD Application to the desired resource graph so Crossplane
	// will reconcile it. The Ready flag reflects whether the application is
	// currently healthy according to its observed status.
	desired[resource.Name(gitopsResourceName)] = &resource.DesiredComposed{
		Resource: gitops,
		Ready:    gitopsReady,
	}

	// ---------------------------------------------------------------------
	// Baseline Application
	// ---------------------------------------------------------------------
	// Build the Helm values for the baseline-tenant chart. These values are used
	// by ArgoCD to deploy the tenant's baseline infrastructure in the workload
	// cluster (namespaces, platform defaults, etc.).

	baselineValues := map[string]any{
		"tenant": map[string]any{
			"name":    name,
			"dnsName": dnsName,
			"owner": map[string]any{
				"team":  team,
				"email": email,
			},
		},
		"environmentPrefix": envPrefix,
	}

	// Serialize the GitOps configuration into YAML for Helm values in the Baseline Application.
	valuesYaml, err = yaml.Marshal(baselineValues)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	baseline := composed.New()

	if existing, ok := desired[resource.Name(baselineResourceName)]; ok {
		baseline = existing.Resource
	}

	f.log.Info(
		"Ensuring baseline application",
		"tenant", name,
	)

	// Declare the desired ArgoCD Application that installs the baseline-tenant Helm chart.
	baseline.SetAPIVersion("argoproj.io/v1alpha1")
	baseline.SetKind("Application")
	baseline.SetName(fmt.Sprintf("baseline-%s", name))
	baseline.SetNamespace("argocd")

	err = baseline.SetValue("spec", map[string]any{
		"project": "default",
		"source": map[string]any{
			"repoURL":        "https://github.com/rezakaramad/kubepave.git",
			"targetRevision": "HEAD",
			"path":           "charts/baseline-tenant",
			"helm": map[string]any{
				"values": string(valuesYaml),
			},
		},
		"destination": map[string]any{
			"name":      "minikube-workload",
			"namespace": name,
		},
		"syncPolicy": map[string]any{
			"automated": map[string]any{
				"prune":    false,
				"selfHeal": true,
			},
		},
	})
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// Add the Baseline Application to the desired resource graph so Crossplane
	// will reconcile it. The Ready flag reflects whether the application is
	// currently healthy according to its observed status.
	desired[resource.Name(baselineResourceName)] = &resource.DesiredComposed{
		Resource: baseline,
		Ready:    baselineReady,
	}

	// ---------------------------------------------------------------------
	// Update XR phase & readiness
	// ---------------------------------------------------------------------
	// Aggregate readiness of all composed resources and update the XR status.
	// When all components are ready, mark the tenant Ready; otherwise keep it
	// in the Provisioning phase so reconciliation continues.

	allReady := groupReady == resource.ReadyTrue &&
		gitopsReady == resource.ReadyTrue &&
		baselineReady == resource.ReadyTrue

	if allReady {

		f.log.Info(
			"Tenant ready",
			"tenant", name,
			"aadGroupID", aadGroupID,
		)

		_ = xr.Resource.SetValue("status.phase", PhaseReady)

		response.ConditionTrue(rsp, "Ready", "Provisioned").
			TargetCompositeAndClaim()

	} else {

		f.log.Info(
			"Tenant still provisioning",
			"tenant", name,
		)

		_ = xr.Resource.SetValue("status.phase", PhaseProvisioning)

		response.ConditionFalse(rsp, "Ready", "Provisioning").
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

// A quick word about the signature:
// This function accepts any value that has a GetString(string) (string, error) method, and returns a bool
// The function takes two inputs: res, conditionType
// res is essentially a Kubernetes resource object
// conditionType could "Ready"
// So the function is asked: Does this resource have condition type "Ready" with status True?
// Input: (resource, condition name)
// Output: true if the resource has that condition with status True
func hasConditionTrue(res interface {
	GetValue(string) (any, error)
}, conditionType string) bool {

	v, err := res.GetValue("status.conditions")
	if err != nil {
		return false
	}

	conds, ok := v.([]any)
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

// Checks whether an ArgoCD Application is fully healthy.
// An application is considered healthy when it is both:
//   - Synced with the desired Git state
//   - Reported as Healthy by ArgoCD
func isArgoAppHealthy(res interface {
	GetString(string) (string, error)
}) bool {

	syncStatus, _ := res.GetString("status.sync.status")
	healthStatus, _ := res.GetString("status.health.status")

	return syncStatus == "Synced" && healthStatus == "Healthy"
}
