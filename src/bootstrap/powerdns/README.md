# PowerDNS Setup (PostgreSQL + API + Admin UI)

This setup provides a PowerDNS authoritative server backed by PostgreSQL, along with a web-based management UI and integration with tools like ExternalDNS.

## Components
### PowerDNS (Authoritative Server)
- Core DNS server responsible for serving zones and records
- Uses PostgreSQL (gpgsql backend) for storage
- Exposes:
    - DNS (TCP/UDP on port 53 → mapped to 1053)
    - HTTP API (port 8081 → mapped to 5380)

### PostgreSQL
- Stores:
    - DNS zones (domains)
    - DNS records (records)
    - metadata (DNSSEC, etc.)
- Initialized via:
    - `schema.pgsql.sql` → creates tables
    - `zones.sql` → seeds initial zones

### PowerDNS Admin (UI)
- Web UI for managing DNS zones, records, and users
- Runs separately from PowerDNS
- Uses its own database (pdns_admin)
- Communicates with PowerDNS via the HTTP API

**NOTE:** PowerDNS Admin does NOT read the database directly — it talks to the API.

You can access the UI via:
```
http://localhost:5388
```

## API

PowerDNS exposes a REST API:
Internal (Docker):

```
http://pdns:8081
```

External (host / Kubernetes):
```
http://localhost:5380
http://host.minikube.internal:5380
```

Example
```
curl -H "X-API-Key: <API_KEY>" \
http://localhost:5380/api/v1/servers/localhost/zones
```


## Networking Model
| Source            | URL                                  |
| ----------------- | ------------------------------------ |
| Docker (internal) | `http://pdns:8081`                   |
| Host machine      | `http://localhost:5380`              |
| Kubernetes        | `http://host.minikube.internal:5380` |

## Architecture Overview
```
        +----------------------+
        |  PowerDNS Admin UI   |
        |  (separate service)  |
        +----------+-----------+
                   |
                   | HTTP API
                   v
        +----------------------+
        |      PowerDNS        |
        |  (authoritative DNS) |
        +----------+-----------+
                   |
                   | SQL (gpgsql)
                   v
        +----------------------+
        |      PostgreSQL      |
        | (zones & records DB) |
        +----------------------+
```

## Usage
Start the stack
```
docker compose up -d
```

Access UI
```
http://localhost:5388
```

Verify API
```
curl -H "X-API-Key: changeme" \
http://localhost:5380/api/v1/servers/localhost
```

## 📚 References

- PowerDNS GitHub: https://github.com/PowerDNS/pdns  
- Official Docs: https://doc.powerdns.com/authoritative/index.html