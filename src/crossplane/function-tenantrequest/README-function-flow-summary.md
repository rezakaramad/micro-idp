# Function Flow

**How `main.go`, `fn.go`, and `powerdns.go` fit together**

```text
main.go
  ├─ creates logger
  ├─ creates Kubernetes client
  ├─ creates PowerDNS client
  ├─ builds Function{ log, kube, pdns, dnsBaseDomain }
  └─ starts Crossplane server with function.Serve(fn)

fn.go
  └─ RunFunction(...)
      ├─ reads the incoming XR from Crossplane
      ├─ validates input
      ├─ checks approval status
      ├─ uses kube client to look up Tenant resources in Kubernetes
      ├─ uses pdns client to check DNS availability
      ├─ builds desired Tenant resource
      └─ returns desired state back to Crossplane

powerdns.go
  └─ implements PDNSClient
      ├─ creates PowerDNS API client
      ├─ sends HTTP request to PowerDNS
      ├─ checks whether the DNS record already exists
      └─ returns Available / Not Available to fn.go
```