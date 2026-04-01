// Package main implements a Composition Function.
package main

import (
	"os"

	"github.com/alecthomas/kong"
	"github.com/crossplane/function-sdk-go"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"

	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
	ctrlconfig "sigs.k8s.io/controller-runtime/pkg/client/config"
)

// CLI of this Function.
type CLI struct {
	Debug bool `help:"Emit debug logs in addition to info logs." short:"d"`

	Network            string `default:"tcp"                                                                                        help:"Network on which to listen for gRPC connections."`
	Address            string `default:":9443"                                                                                      help:"Address at which to listen for gRPC connections."`
	TLSCertsDir        string `env:"TLS_SERVER_CERTS_DIR"                                                                           help:"Directory containing server certs (tls.key, tls.crt) and the CA used to verify client certificates (ca.crt)"`
	Insecure           bool   `help:"Run without mTLS credentials. If you supply this flag --tls-server-certs-dir will be ignored."`
	MaxRecvMessageSize int    `default:"4"                                                                                          help:"Maximum size of received messages in MB."`
}

// Run this Function.
func (c *CLI) Run() error {
	log, err := function.NewLogger(c.Debug)
	if err != nil {
		return err
	}

	// ------------------------------------------------------------------
	// Build Kubernetes client
	// ------------------------------------------------------------------

	cfg, err := ctrlconfig.GetConfig()
	if err != nil {
		return err
	}

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))

	kubeClient, err := ctrlclient.New(cfg, ctrlclient.Options{
		Scheme: scheme,
	})
	if err != nil {
		return err
	}

	pdnsClient := NewPowerDNSClient(
		getEnv("PDNS_API_URL", "http://host.minikube.internal:5380/api/v1"),
		getEnv("PDNS_API_KEY", ""),
	)

	// ------------------------------------------------------------------
	// Function setup
	// ------------------------------------------------------------------

	fn := &Function{
		log:           log,
		kube:          kubeClient,
		pdns:          pdnsClient,
		dnsBaseDomain: getEnv("DNS_BASE_DOMAIN", "rezakara.demo"),
	}

	return function.Serve(fn,
		function.Listen(c.Network, c.Address),
		function.MTLSCertificates(c.TLSCertsDir),
		function.Insecure(c.Insecure),
		function.MaxRecvMessageSize(c.MaxRecvMessageSize*1024*1024))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	ctx := kong.Parse(&CLI{}, kong.Description("A Crossplane Composition Function."))
	ctx.FatalIfErrorf(ctx.Run())
}
