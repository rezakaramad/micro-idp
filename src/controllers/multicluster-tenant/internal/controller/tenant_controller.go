package controller

// +kubebuilder:rbac:groups=m.idp.rezakaramad.local,resources=tenants,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=m.idp.rezakaramad.local,resources=tenants/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=m.idp.rezakaramad.local,resources=tenants/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch

import (
	// Standard library
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	// Kubernetes API types
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"

	// Kubernetes client configuration
	"k8s.io/client-go/rest"

	// Controller-runtime framework
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	// Logging and API types
	"github.com/go-logr/logr"
	midpv1alpha1 "github.com/rezakaramad/kubepave/src/controllers/tenant/api/v1alpha1"
)

// Defines your platform conventions
const (
	TenantFinalizer = "m.idp.rezakaramad.local/finalizer"

	ClusterSecretLabelKey   = "m.idp.rezakaramad.local/type"
	ClusterSecretLabelValue = "cluster"

	ManagedByLabel = "m.idp.rezakaramad.local/managed"
	TenantLabel    = "m.idp.rezakaramad.local/tenant"

	ConditionReady = "Ready"

	PerClusterTimeout = 10 * time.Second
	RetryAfter        = 30 * time.Second
)

// Control plane
// TenantReconciler reconciles a Tenant object
type TenantReconciler struct {
	client.Client                 // talks to Kubernetes (CRUD operations)
	Scheme        *runtime.Scheme // tells the client what types exist (like Tenant, Namespace, etc.)

	WatchNamespace string // where cluster secrets live

	mu sync.RWMutex // a lock (for safe concurrency)

	// We cache clients per cluster to avoid rebuilding REST configs on every reconcile,
	// which is expensive and can cause connection churn.
	clientCache map[string]client.Client
}

// Multi-cluster abstraction boundary
type ClusterConnection struct {
	Name        string
	Server      string
	BearerToken string
	Insecure    bool
	CAData      []byte
}

// Visual flow
// Reconcile starts
//
//	↓
//
// GET object
//
//	├── fail → return (ignore if err is “NotFound”, or error if err is something else)
//	↓
//
// Check deletion
//
//	├── yes → return reconcileDelete(...)
//	↓
//
// Check finalizer
//
//	├── missing → add it
//	│      ├── update fails → return error
//	│      └── success → return Requeue:true
//	↓
//
// (continues to next part of code...)
func (r *TenantReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx).WithValues("tenant", req.Name)

	// Create an empty struct
	// tenant = {}
	var tenant midpv1alpha1.Tenant

	// Get the Tenant object from Kubernetes
	// 'r.Get(...)' fetches data from Kubernetes and fills the object.
	// The below line means “using this request context, fetch the object identified by this name, and store it in tenant”
	if err := r.Get(ctx, req.NamespacedName, &tenant); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// If deletion timestamp is set: Kubernetes is deleting this object
	// Checking DeletionTimestamp is the canonical way to detect deletion in controllers
	// In K8s, deletion is not immediate but when you delete something,
	// K8s basically marks the object for deletion by stamptimg the time deletion happened.
	// Must clean up external resources first
	if !tenant.DeletionTimestamp.IsZero() {
		return r.reconcileDelete(ctx, log, &tenant)
	}

	// Block deletion until I finish clean up
	if !controllerutil.ContainsFinalizer(&tenant, TenantFinalizer) {
		log.Info("Adding finalizer")
		controllerutil.AddFinalizer(&tenant, TenantFinalizer)

		// r.Update(...) = “send this modified object to the Kubernetes API server and store it”
		// A little about the syntax: if <initialization>; <condition> {...}
		if err := r.Update(ctx, &tenant); err != nil {
			return ctrl.Result{}, err
		}

		// What is reconcile
		// controller-runtime (the system) calls your Reconcile function
		// What is requeue
		// requeue = call my Reconcile function again for this object
		// ctrl.Result{} = Reconcile(tenant-a) → (done) → WAIT for new event
		// ctrl.Result{Requeue: true} = Reconcile(tenant-a) → (done) → IMMEDIATELY call again → Reconcile(tenant-a)
		// Think of it like a queue; controller-runtime has a queue like:
		// [tenant-a, tenant-b, tenant-c]
		// Requeue means: put tenant-a back into the queue

		// Run Reconcile again immediately
		return ctrl.Result{Requeue: true}, nil
	}

	return r.reconcileUpsert(ctx, log, &tenant)
}

// Tenant exists → ensure “for this Tenant, a namespace exists in all clusters”
// Controller r processes this tenant and decides what happens next
func (r *TenantReconciler) reconcileUpsert(
	ctx context.Context,
	log logr.Logger,
	tenant *midpv1alpha1.Tenant,
) (ctrl.Result, error) {
	log.Info("Reconciling tenant")

	// Discover clusters via Secrets
	clusterSecrets, err := r.listClusterSecrets(ctx)
	if err != nil {
		log.Error(err, "Failed to list cluster secrets")
		// Can’t even discover clusters → retry later
		return ctrl.Result{}, err
	}

	log.Info("Discovered cluster secrets", "count", len(clusterSecrets))

	// For each cluster, connect and then creates resources
	// Briefly about how we call 'forEachCluster' function:
	// We are passing a function into another function, so it can run your logic for each cluster
	// forEachCluster = “loop over clusters + setup connection”
	// And then we say: what should happen inside each cluster
	// Means “for each cluster: run THIS function I’m giving you”
	err = r.forEachCluster(
		ctx,
		log,
		clusterSecrets,
		func(
			ctx context.Context,
			clusterLog logr.Logger,
			clusterClient client.Client,
			conn *ClusterConnection,
		) error {
			clusterLog.Info("Ensuring namespace", "namespace", tenant.Name)

			if err := r.ensureNamespace(ctx, clusterClient, tenant.Name); err != nil {
				return fmt.Errorf("ensure namespace in cluster %q: %w", conn.Name, err)
			}

			clusterLog.Info("Namespace ensured", "namespace", tenant.Name)
			return nil
		})

	// If partial failure:
	// 	1. Mark Tenant as NOT ready
	// 	2. Schedule retry after some time
	if err != nil {
		log.Error(err, "Tenant reconciled with partial failures")
		_ = r.setTenantReadyCondition(ctx, tenant, metav1.ConditionFalse, "PartiallyReady", err.Error())
		// Try again after some time
		return ctrl.Result{RequeueAfter: RetryAfter}, nil
	}

	// All clusters succeeded → mark Tenant as Ready
	if err := r.setTenantReadyCondition(ctx, tenant, metav1.ConditionTrue, "Reconciled", "Tenant namespace ensured in all clusters"); err != nil {
		log.Error(err, "Failed to update tenant status")
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// Tenant deleted → namespace removed from all clusters
func (r *TenantReconciler) reconcileDelete(
	ctx context.Context,
	log logr.Logger,
	tenant *midpv1alpha1.Tenant,
) (ctrl.Result, error) {
	log.Info("Reconciling deletion")

	// If no cleanup (finalizer) → do nothing
	if !controllerutil.ContainsFinalizer(tenant, TenantFinalizer) {
		return ctrl.Result{}, nil
	}

	clusterSecrets, err := r.listClusterSecrets(ctx)
	if err != nil {
		log.Error(err, "Failed to list cluster secrets")
		return ctrl.Result{}, err
	}

	err = r.forEachCluster(ctx, log, clusterSecrets, func(ctx context.Context, clusterLog logr.Logger, clusterClient client.Client, conn *ClusterConnection) error {
		clusterLog.Info("Deleting namespace", "namespace", tenant.Name)

		if err := r.deleteNamespace(ctx, clusterClient, tenant.Name); err != nil {
			return fmt.Errorf("delete namespace in cluster %q: %w", conn.Name, err)
		}

		clusterLog.Info("Namespace deleted (or already gone)", "namespace", tenant.Name)
		return nil
	})

	if err != nil {
		log.Error(err, "Deletion reconciled with partial failures")
		// Keep the finalizer so Kubernetes retries deletion cleanup later.
		return ctrl.Result{RequeueAfter: RetryAfter}, nil
	}

	log.Info("All clusters cleaned up, removing finalizer")
	controllerutil.RemoveFinalizer(tenant, TenantFinalizer)

	if err := r.Update(ctx, tenant); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
// Watch Tenant objects, call Reconcile when they change
// Register my controller and tell the system what I watch
func (r *TenantReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// The controller looks for cluster secrets, it needs to know which name should it look in
	if r.WatchNamespace == "" {
		r.WatchNamespace = os.Getenv("POD_NAMESPACE")
		if r.WatchNamespace == "" {
			r.WatchNamespace = "default"
		}
	}

	// clientCache = connection pool for clusters
	if r.clientCache == nil {
		r.clientCache = make(map[string]client.Client)
	}

	// Register controller
	return ctrl.NewControllerManagedBy(mgr).
		// This tells controller-runtime: whenever a Tenant changes → call Reconcile
		For(&midpv1alpha1.Tenant{}).
		// Give this controller a name (used in logs/metrics)
		Named("tenant").
		// Use r (TenantReconciler) as the Reconcile implementation
		Complete(r)
}

// Cluster Discovery
func (r *TenantReconciler) listClusterSecrets(ctx context.Context) ([]corev1.Secret, error) {
	var secretList corev1.SecretList

	// List Secret resources with a specific label
	err := r.List(ctx, &secretList,
		client.InNamespace(r.WatchNamespace),
		client.MatchingLabels{
			ClusterSecretLabelKey: ClusterSecretLabelValue,
		},
	)
	if err != nil {
		return nil, err
	}

	return secretList.Items, nil
}

// Multi-cluster execution engine
// loop clusters → connect → execute
func (r *TenantReconciler) forEachCluster(
	ctx context.Context,
	log logr.Logger,
	secrets []corev1.Secret,
	operation func(ctx context.Context, clusterLog logr.Logger, c client.Client, conn *ClusterConnection) error,
) error {
	var errs []error

	for _, secret := range secrets {

		if ctx.Err() != nil {
			return ctx.Err()
		}

		clusterLog := log.WithValues("cluster", secret.Name)

		// Connect to cluster
		conn, err := r.parseClusterConnection(secret)
		if err != nil {
			clusterLog.Error(err, "Failed to parse cluster connection")
			errs = append(errs, fmt.Errorf("parse cluster connection %q: %w", secret.Name, err))
			continue
		}

		// Build cluster client, if exists reuse
		clusterClient, err := r.getClusterClient(conn)
		if err != nil {
			clusterLog.Error(err, "Failed to get cluster client")
			errs = append(errs, fmt.Errorf("get cluster client %q: %w", conn.Name, err))
			continue
		}

		clusterCtx, cancel := context.WithTimeout(ctx, PerClusterTimeout)
		err = operation(clusterCtx, clusterLog, clusterClient, conn)
		cancel()

		if err != nil {
			clusterLog.Error(err, "Cluster operation failed")
			errs = append(errs, err)
			continue
		}
	}

	return errors.Join(errs...)
}

// Transforms Secret → ClusterConnection
func (r *TenantReconciler) parseClusterConnection(secret corev1.Secret) (*ClusterConnection, error) {
	conn := &ClusterConnection{
		Name: secret.Name,
	}

	serverBytes, ok := secret.Data["server"]
	if !ok || len(serverBytes) == 0 {
		return nil, fmt.Errorf("cluster %q: missing server", secret.Name)
	}
	conn.Server = string(serverBytes)

	configBytes, ok := secret.Data["config"]
	if !ok || len(configBytes) == 0 {
		return nil, fmt.Errorf("cluster %q: missing config", secret.Name)
	}

	var cfg struct {
		BearerToken     string `json:"bearerToken"`
		TLSClientConfig struct {
			Insecure bool   `json:"insecure"`
			CAData   []byte `json:"caData"`
		} `json:"tlsClientConfig"`
	}

	if err := json.Unmarshal(configBytes, &cfg); err != nil {
		return nil, fmt.Errorf("cluster %q: unmarshal config: %w", secret.Name, err)
	}

	if cfg.BearerToken == "" {
		return nil, fmt.Errorf("cluster %q: missing bearerToken", secret.Name)
	}

	conn.BearerToken = cfg.BearerToken
	conn.Insecure = cfg.TLSClientConfig.Insecure
	conn.CAData = cfg.TLSClientConfig.CAData

	return conn, nil
}

// Builds a Kubernetes client configuration directly from structured connection details.
func (r *TenantReconciler) buildRestConfigFromConnection(conn *ClusterConnection) *rest.Config {
	return &rest.Config{
		Host:        conn.Server,
		BearerToken: conn.BearerToken,
		TLSClientConfig: rest.TLSClientConfig{
			Insecure: conn.Insecure,
			CAData:   conn.CAData,
		},
	}
}

// Connection pool → caches clients per cluster
func (r *TenantReconciler) getClusterClient(conn *ClusterConnection) (client.Client, error) {
	r.mu.RLock()
	cached, ok := r.clientCache[conn.Name]
	r.mu.RUnlock()
	if ok {
		return cached, nil
	}

	restConfig := r.buildRestConfigFromConnection(conn)

	clusterClient, err := client.New(restConfig, client.Options{
		Scheme: r.Scheme,
	})
	if err != nil {
		return nil, err
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if existing, ok := r.clientCache[conn.Name]; ok {
		return existing, nil
	}

	r.clientCache[conn.Name] = clusterClient
	return clusterClient, nil
}

// Business logic
// Create namespace if not exists
func (r *TenantReconciler) ensureNamespace(
	ctx context.Context,
	c client.Client,
	name string,
) error {
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, c, ns, func() error {
		if ns.Labels == nil {
			ns.Labels = map[string]string{}
		}

		ns.Labels[ManagedByLabel] = "true"
		ns.Labels[TenantLabel] = name
		return nil
	})

	return err
}

// Delete namespace if exists
func (r *TenantReconciler) deleteNamespace(
	ctx context.Context,
	c client.Client,
	name string,
) error {
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
	}

	err := c.Delete(ctx, ns)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}

	return nil
}

func (r *TenantReconciler) setTenantReadyCondition(
	ctx context.Context,
	tenant *midpv1alpha1.Tenant,
	status metav1.ConditionStatus,
	reason, message string,
) error {
	base := tenant.DeepCopy()

	tenant.Status.ObservedGeneration = tenant.Generation
	apimeta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
		Type:               ConditionReady,
		Status:             status,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: tenant.Generation,
		LastTransitionTime: metav1.Now(),
	})

	return r.Status().Patch(ctx, tenant, client.MergeFrom(base))
}
