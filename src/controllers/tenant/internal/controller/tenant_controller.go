package controller

import (
	"context"
	"fmt"
	"os"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	idpv1alpha1 "github.com/rezakaramad/kubepave/src/controllers/tenant/api/v1alpha1"
)

const tenantFinalizer = "idp.rezakara.demo/finalizer"

// TenantReconciler reconciles a Tenant object
type TenantReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=idp.rezakara.demo,resources=tenants,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=idp.rezakara.demo,resources=tenants/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=idp.rezakara.demo,resources=tenants/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch;create;delete
func (r *TenantReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {

	logger := log.FromContext(ctx)

	var tenant idpv1alpha1.Tenant

	if err := r.Get(ctx, req.NamespacedName, &tenant); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	role := os.Getenv("ROLE")

	var namespaceName string

	switch role {
	case "controlplane":
		namespaceName = fmt.Sprintf("gitops-%s", tenant.Name)
	case "runtime":
		namespaceName = tenant.Name
	default:
		return ctrl.Result{}, fmt.Errorf("ROLE must be controlplane or runtime")
	}

	logger.Info("Reconciling tenant",
		"tenant", tenant.Name,
		"namespace", namespaceName,
		"role", role,
	)

	// ----------------------------------
	// Handle deletion
	// ----------------------------------
	if !tenant.DeletionTimestamp.IsZero() {

		if controllerutil.ContainsFinalizer(&tenant, tenantFinalizer) {

			var ns corev1.Namespace
			err := r.Get(ctx, client.ObjectKey{Name: namespaceName}, &ns)

			if err == nil {

				if ns.DeletionTimestamp.IsZero() {

					logger.Info("Deleting namespace", "namespace", namespaceName)

					if err := r.Delete(ctx, &ns); err != nil {
						return ctrl.Result{}, err
					}
				}

				// Wait until namespace disappears
				return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
			}

			if !apierrors.IsNotFound(err) {
				return ctrl.Result{}, err
			}

			logger.Info("Namespace deleted, removing finalizer")

			controllerutil.RemoveFinalizer(&tenant, tenantFinalizer)

			if err := r.Update(ctx, &tenant); err != nil {
				return ctrl.Result{}, err
			}
		}

		return ctrl.Result{}, nil
	}

	// ----------------------------------
	// Ensure finalizer
	// ----------------------------------
	if !controllerutil.ContainsFinalizer(&tenant, tenantFinalizer) {

		logger.Info("Adding finalizer")

		controllerutil.AddFinalizer(&tenant, tenantFinalizer)

		if err := r.Update(ctx, &tenant); err != nil {
			return ctrl.Result{}, err
		}

		return ctrl.Result{Requeue: true}, nil
	}

	// ----------------------------------
	// Ensure namespace exists
	// ----------------------------------
	var ns corev1.Namespace

	err := r.Get(ctx, client.ObjectKey{Name: namespaceName}, &ns)

	if err != nil && apierrors.IsNotFound(err) {

		logger.Info("Creating namespace", "namespace", namespaceName)

		ns = corev1.Namespace{
			ObjectMeta: ctrl.ObjectMeta{
				Name: namespaceName,
				Labels: map[string]string{
					"tenant": tenant.Name,
				},
			},
		}

		if err := r.Create(ctx, &ns); err != nil {
			return ctrl.Result{}, err
		}

		return ctrl.Result{Requeue: true}, nil
	}

	if err != nil {
		return ctrl.Result{}, err
	}

	// ----------------------------------
	// Update status condition
	// ----------------------------------
	condition := metav1.Condition{
		Type:               "TenantReady",
		Status:             metav1.ConditionTrue,
		Reason:             "NamespaceReady",
		Message:            "Tenant namespace exists",
		LastTransitionTime: metav1.Now(),
	}

	meta.SetStatusCondition(&tenant.Status.Conditions, condition)

	if err := r.Status().Update(ctx, &tenant); err != nil {
		logger.Error(err, "unable to update tenant status")
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *TenantReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&idpv1alpha1.Tenant{}).
		Named("tenant").
		Complete(r)
}
