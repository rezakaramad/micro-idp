# PowerDNS Setup (PostgreSQL + API + Admin UI)

This setup provides a PowerDNS authoritative server backed by PostgreSQL, along with a web-based management UI which is integrated with Kubernetes using ExternalDNS.

## Components
### PowerDNS (Authoritative Server)
- Uses PostgreSQL for storage
- Exposes:
    - DNS (TCP/UDP on port `53`)
    - HTTP API (port `8081` → mapped to `5380`)
        - `8081` is used internally while `5380` is called externally

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
- Uses its own database (`pdns_admin`)
- Communicates with PowerDNS via the HTTP API
    - PowerDNS Admin → PowerDNS API (TCP on port `8081`)
    - It's an internal call

**NOTE:** PowerDNS Admin does NOT read the database directly — it talks to the API.

You can access the PowerDNS Admin UI via:
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

If it starts successfully, you should see something like this when you run:
```
❯ docker ps
CONTAINER ID   IMAGE                             COMMAND                  CREATED      STATUS                PORTS                                                                                     NAMES
3fa0c3e681ca   powerdnsadmin/pda-legacy:latest   "entrypoint.sh gunic…"   2 days ago   Up 2 days (healthy)   0.0.0.0:5388->80/tcp, [::]:5388->80/tcp                                                   pdns-admin
5f4131d37303   powerdns/pdns-auth-51:latest      "/usr/bin/tini -- /u…"   2 days ago   Up 2 days             127.0.0.1:53->53/tcp, 127.0.0.1:53->53/udp, 0.0.0.0:5380->8081/tcp, [::]:5380->8081/tcp   pdns
52f7cd973934   postgres:17                       "docker-entrypoint.s…"   2 days ago   Up 2 days (healthy)   5432/tcp                                                                                  pdns-db

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
