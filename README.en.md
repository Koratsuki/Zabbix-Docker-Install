# Zabbix on Docker (Zabbix + PostgreSQL)

**Zabbix 7.4** monitoring platform deployed with Docker Compose on top of
**PostgreSQL 18**, following the official Zabbix container pattern:

| Service               | Image                                         | Version  |
|-----------------------|-----------------------------------------------|----------|
| Database              | `postgres:18-alpine`                          | 18.6     |
| Zabbix server         | `zabbix/zabbix-server-pgsql`                  | 7.4.14   |
| Web frontend (nginx)  | `zabbix/zabbix-web-nginx-pgsql`               | 7.4.14   |
| Zabbix agent (native) | `zabbix/zabbix-agent`                         | 7.4.14   |

> All four containers use the **alpine** variant (lightweight image) and the
> standard Zabbix `public` database schema on top of PostgreSQL.

---

## Architecture

```
                          │ 192.168.20.105  (zabbix-01 · Ubuntu 26.04 LTS)
                          │
        ┌─────────────────┴──────────────────────────┐
        │              Internal net zbx_net          │
        │              (bridge · 172.18.0.0/16)      │
        │                                            │
        │   ┌────────────┐    ┌───────────────┐      │
        │   │  zabbix-   │───▶│  zabbix-      │      │
        │   │  pgsql     │    │  server       │      │
        │   │  :5432     │    │  :10051       │      │
        │   └────────────┘    │  ┌────────────┤      │
        │                     │  │ zabbix-    │      │
        │                     │  │ agent      │◀─┐   │
        │   ┌────────────┐    │  │ :10050     │  │   │
        │   │  zabbix-   │◀───│  └────────────┘  │   │
        │   │  web (nginx)│    │       ▲ self-    │   │
        │   │  :8080     │    │       │ monitor  │   │
        │   └─────┬──────┘    └───────┴──────────┘   │
        └─────────┼──────────────────────────────────┘
                  │ 127.0.0.1:8080 (local only)
```

* **zabbix-server** connects to the DB (`pgsql-server`), processes data, fires
  triggers and manages the checks queue.
* **zabbix-agent** monitors the host itself *"Zabbix server"* (CPU, memory,
  network, disk... items).
* **zabbix-web** exposes the web UI (nginx + PHP-FPM) on `127.0.0.1:8080`.

---

## Host requirements

| Resource       | Value                                          |
|----------------|------------------------------------------------|
| OS             | Ubuntu 26.04.1 LTS (kernel 6.x)                |
| CPU            | 4 vCPU (AMD Ryzen 5 5500U)                     |
| Memory         | 7.2 GiB (the stack reserves 1 GiB for pgsql)   |
| Disk           | 54 GiB (≈38 GiB free)                          |
| Docker Engine  | ≥ 29.x                                         |
| Docker Compose | `docker compose` plugin ≥ 2.x (v5.5.1 in use)  |

---

## Project layout

```
/opt/zabbix
├── docker-compose.yml        # Stack definition (4 services)
├── config/
│   ├── pgsql.env             # PostgreSQL credentials/setup
│   ├── postgres.conf         # PostgreSQL configuration (tuning)
│   ├── pg_hba.conf           # Database access authentication rules
│   ├── initdb.d/             # Scripts PostgreSQL runs on first init
│   │   └── 00_extensions.sh  #   → CREATE EXTENSION pg_stat_statements
│   ├── zabbix-server.env     # Zabbix server DB connection
│   ├── zabbix-web.env        # Zabbix web DB connection + frontend
│   └── zabbix-agent.env      # Agent configuration (hostname, server)
├── data/
│   └── pgsql/                # PERSISTENT PostgreSQL data (bind mount)
│       └── 18/docker/        # Instance PGDATA
├── README.md                 # This document (English: README.en.md)
└── INSTALL.md                # Installation guide (English: INSTALL.en.md)
```

> **Important:** `data/pgsql` is the permanent storage of the database. Do not
> delete it if you want to keep your monitoring history. It is mounted to
> `/var/lib/postgresql/18/docker` inside the container.

---

## Exposed ports

| Port         | Service            | Bind                         | Purpose                               |
|--------------|--------------------|------------------------------|---------------------------------------|
| `8080/tcp`   | zabbix-web         | `127.0.0.1` (local only)     | Zabbix web UI (HTTP)                  |
| `8443/tcp`   | zabbix-web         | internal (container)         | HTTPS (not active: missing certs)     |
| `10051/tcp`  | zabbix-server      | `0.0.0.0`                    | Ingress for agents/active proxies     |
| `10050/tcp`  | zabbix-agent       | `0.0.0.0`                    | Server queries (passive checks)       |
| `5432/tcp`   | zabbix-pgsql       | `127.0.0.1` (local only)     | Administrative access to PostgreSQL   |

---

## Default credentials

| Component         | User       | Password                 |
|-------------------|-----------|--------------------------|
| Zabbix frontend   | `Admin`   | `zabbix`                 |
| PostgreSQL        | `postgres`| defined in `config/pgsql.env` |

> **Change the `Admin` password right away.** The DB password lives in the
> `config/*.env` files; if you change it, update **all** env files and restart
> the stack (the three services share credentials).

---

## Common operations

All commands run as `sysadmin` on the host (they require `sudo` to talk to the
Docker daemon).

```bash
cd /opt/zabbix

# Start the stack
sudo docker compose up -d

# Container status
sudo docker compose ps

# Logs of a specific service
sudo docker compose logs -f zabbix-server

# Restart a service
sudo docker compose restart zabbix-server

# Stop everything (data persists in ./data/pgsql)
sudo docker compose down

# Stop and remove containers + network (does NOT remove data/pgsql)
sudo docker compose down --remove-orphans

# Show resolved/effective configuration
sudo docker compose config
```

### Quick health check

```bash
# All containers up, web/pgsql "healthy"
sudo docker ps --format "table {{.Names}}\t{{.Status}}"

# PostgreSQL healthcheck status
sudo docker inspect --format "{{.State.Health.Status}}" zabbix-pgsql

# Web UI responds
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080     # → 200

# Server can read metrics from the local agent
sudo docker exec zabbix-server zabbix_get -s zabbix-agent -k system.uptime
```

### Database access

```bash
sudo docker exec -it zabbix-pgsql psql -U postgres -d zabbix
```

Extensions installed in all DBs: `plpgsql` and `pg_stat_statements`.
`pg_stat_statements` is enabled in `postgres.conf` via
`shared_preload_libraries` and is **installed automatically on first start**
by the `config/initdb.d/00_extensions.sh` script (run by
`docker-entrypoint.sh` only when the datadir is empty). It is also installed
in `template1` so that any database created afterwards (like `zabbix`)
inherits it.

If you start from an already-existing datadir (created without the script),
install it manually:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d postgres -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

---

## Notable configuration

### `config/postgres.conf`
Standalone PostgreSQL parameters (without modifying the container's defaults):
* Memory: `shared_buffers=512MB`, `effective_cache_size=1GB`,
  `work_mem=16MB`.
* WAL: `wal_level=replica`, `max_wal_size=2GB`, checkpoints every 15 min.
* Enhanced autovacuum (4 workers) for Zabbix history tables.
* Logs: daily files `log/postgresql-%Y-%m-%d.log`, `log_min_duration_statement=300ms`.
* `shared_preload_libraries='pg_stat_statements'`.

### PostgreSQL healthcheck
`pgsql-server` exposes a healthcheck (`pg_isready -U $POSTGRES_USER -d
postgres`, every 10 s with a 30 s `start_period`). `zabbix-server` and
`zabbix-web` wait for the DB to be **healthy** (`depends_on.condition:
service_healthy`) before starting, avoiding startup races. See status with
`sudo docker ps --format "{{.Names}} {{.Status}}"`.

### `config/pg_hba.conf`
Access rules: `trust` on local socket, `md5` for 127.0.0.1, 10/8,
172.16/12 (internal docker risk) and 0.0.0.0/0. The port is only published on
**127.0.0.1**, so external access is blocked at the Docker level.

### `config/*.env`
Credentials and connection variables. The web file points to the server and
the DB by container name (Docker DNS resolution).

### `config/initdb.d/`
Mounted to `/docker-entrypoint-initdb.d`, it is the standard mechanism of the
`postgres` image to run scripts **only on the first init** (empty datadir).
Here the `pg_stat_statements` extension is created. An existing datadir
**never** reruns them.

---

## Upgrading the stack

1. Take a backup of the DB (see below).
2. Bump the image tags in `docker-compose.yml` (e.g. `7.4-alpine-latest` →
   `7.6-alpine-latest`).
3. `sudo docker compose pull && sudo docker compose up -d`
4. Verify the server reports the new version:
   `sudo docker logs zabbix-server 2>&1 | grep "current database version"`.

> Zabbix applies its own schema changes on startup. For major versions, read
> the DB compatibility notes first.

---

## Backup and restore

### Logical backup (pg_dump)

```bash
# Dump of the "zabbix" DB
sudo docker exec zabbix-pgsql pg_dump -U postgres -d zabbix -Fc -f /tmp/zabbix.dump
sudo docker cp zabbix-pgsql:/tmp/zabbix.dump ~/zabbix-$(date +%F).dump

# Native PostgreSQL dump (data + SQL schema)
sudo docker exec zabbix-pgsql pg_dumpall -U postgres > ~/pgdumpall-$(date +%F).sql
```

> The simplest full "snapshot" is a copy of the `data/pgsql` directory with
> the service stopped (PGDATA copy-out).

### Restore

```bash
sudo docker cp ~/zabbix.dump zabbix-pgsql:/tmp/
sudo docker exec zabbix-pgsql pg_restore -U postgres -d zabbix \
  --clean --if-exists /tmp/zabbix.dump
```

---

## Security

* The web listens only on `127.0.0.1` — for external access publish the port
  and use HTTPS (the container looks for certificates under `/etc/ssl/nginx`;
  without them it starts in HTTP).
* Ports `10050`/`10051` are bound to all interfaces: restrict them to your
  agents' IPs in the firewall (`ufw allow from <agent_ip> to any port
  10050,10051 proto tcp`).
* `pg_hba.conf` accepts `md5` from any host (`0.0.0.0/0`): consider
  `scram-sha-256` and narrowing the source network unless it is a lab
  environment.
* Change the default passwords (`Admin/zabbix` and the `postgres` one).

---

## Troubleshooting

| Symptom                                        | Likely cause / solution                                       |
|------------------------------------------------|--------------------------------------------------------------|
| Web responds but "Database is not initialized" | Wait for `zabbix-server` to create the schema; check `docker logs zabbix-server` |
| `FATAL: database "zabbix" does not exist`      | The server has not created the DB yet (first start)          |
| "Zabbix server" host items red                 | Agent not registered: check `config/zabbix-agent.env` (`ZBX_HOSTNAME` must match host "Zabbix server") |
| *"1024 file descriptors insufficient"* warning | Already fixed: `ulimits.nofile` = 65536 in the compose       |
| DB password: `FATAL: password authentication failed` | Password changed in only one env file; update `config/pgsql.env`, `zabbix-server.env` and `zabbix-web.env` |
| `dial unix /var/run/docker.sock` denied        | Run with `sudo` (the `docker` group is not granted to sysadmin) |

---

## References

* [Zabbix docs — docker containers](https://www.zabbix.com/documentation/current/manual/installation/containers)
* [Zabbix Docker images (GitHub)](https://github.com/zabbix/zabbix-docker)
* [Zabbix image registry](https://hub.docker.com/u/zabbix)
* [PostgreSQL documentation](https://www.postgresql.org/docs/current/runtime-config.html)