# INSTALL — Installing Zabbix (Docker containers) on Ubuntu

Step-by-step guide to deploy the **Zabbix 7.4 + PostgreSQL 18** stack with
Docker Compose. Includes the test environment reference: host
`zabbix-01` (192.168.20.105), Ubuntu 26.04 LTS.

---

## 1. Prerequisites

* Ubuntu 22.04 or newer (tested on 26.04.1 LTS).
* A user with `sudo` (in this environment: `sysadmin`).
* Recommended minimum: 2 CPU, 4 GiB RAM, 20 GiB free disk.

```bash
sudo apt update && sudo apt upgrade -y
```

## 2. Install Docker Engine and the Compose plugin

Install Docker from the official Docker repository (not the Ubuntu packages):

```bash
# Prerequisite packages
sudo apt install -y ca-certificates curl

# Docker key and repository
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

> Your distribution codename (`$(VERSION_CODENAME)`) must be supported by
> Docker; on Ubuntu 26.04 use `noble` if the codename is not yet published.

Add your user to the `docker` group to avoid typing `sudo` on every command
(optional; this installation uses `sudo`):

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

Verify:

```bash
sudo docker run --rm hello-world
docker compose version    # → Docker Compose version v2.x+ (in use: v5.5.1)
```

## 3. Create the directory structure

```bash
sudo mkdir -p /opt/zabbix/{config,data/pgsql}
```

From here on, all project files are assumed to live in `/opt/zabbix`
(docker-compose.yml, config/, data/).

## 4. Writing the project files

Create each file listed below. The `.env` files share the **same** PostgreSQL
credentials (in this deployment the user is `postgres` and the Zabbix DB is
named `zabbix`).

### 4.1 `docker-compose.yml`

```yaml
---
services:
  pgsql-server:
    image: postgres:18-alpine
    container_name: zabbix-pgsql
    restart: unless-stopped
    shm_size: 512mb
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    env_file: ./config/pgsql.env
    volumes:
      - ./data/pgsql:/var/lib/postgresql
      - ./config/postgres.conf:/etc/postgresql/postgresql.conf:ro
      - ./config/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./config/initdb.d:/docker-entrypoint-initdb.d:ro
    command: >
      postgres
      -c config_file=/etc/postgresql/postgresql.conf
      -c hba_file=/etc/postgresql/pg_hba.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    ports:
      - 127.0.0.1:5432:5432
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 1G
        reservations:
          memory: 1G
    networks:
      - zbx_net

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:7.4-alpine-latest
    container_name: zabbix-server
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    env_file: ./config/zabbix-server.env
    depends_on:
      pgsql-server:
        condition: service_healthy
    ports:
      - "10051:10051"
    networks:
      - zbx_net

  zabbix-agent:
    image: zabbix/zabbix-agent:7.4-alpine-latest
    container_name: zabbix-agent
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    env_file: ./config/zabbix-agent.env
    depends_on:
      - zabbix-server
    ports:
      - "10050:10050"
    networks:
      - zbx_net

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:7.4-alpine-latest
    container_name: zabbix-web
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    env_file: ./config/zabbix-web.env
    depends_on:
      pgsql-server:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    ports:
      - 127.0.0.1:8080:8080
    networks:
      - zbx_net

networks:
  zbx_net:
```

> Do not use `VARIABLE: value` syntax in the env files: the valid Docker
> Compose format is `VARIABLE=value`.
>
> The `./config/initdb.d:/docker-entrypoint-initdb.d:ro` volume is what
> automates extension creation (see 4.8).

### 4.2 `config/pgsql.env`

```ini
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<SAME_PASSWORD_EVERYWHERE>
TZ=UTC
```

### 4.3 `config/zabbix-server.env`

```ini
DB_SERVER_HOST=pgsql-server
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<SAME_PASSWORD_EVERYWHERE>
POSTGRES_DB=zabbix
```

### 4.4 `config/zabbix-web.env`

```ini
DB_SERVER_HOST=pgsql-server
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<SAME_PASSWORD_EVERYWHERE>
POSTGRES_DB=zabbix
ZBX_SERVER_HOST=zabbix-server
ZBX_SERVER_PORT=10051
PHP_TZ=UTC
```

### 4.5 `config/zabbix-agent.env`

```ini
ZBX_SERVER_HOST=zabbix-server
ZBX_SERVER_PORT=10051
ZBX_HOSTNAME=Zabbix server
ZBX_LISTENPORT=10050
```

> `ZBX_HOSTNAME` must match exactly the host name the server creates
> automatically ("Zabbix server"); otherwise the items of the host itself end
> up in "Not supported" state.

### 4.6 `config/postgres.conf`

PostgreSQL tuning tuned for Zabbix: memory, WAL, autovacuum and logging.
Reference content from the deployment:

```ini
listen_addresses = '*'
port = 5432
max_connections = 150

shared_buffers = 512MB
work_mem = 16MB
maintenance_work_mem = 512MB
effective_cache_size = 1GB

wal_level = replica
wal_buffers = 32MB
checkpoint_completion_target = 0.9
checkpoint_timeout = 15min
max_wal_size = 2GB
min_wal_size = 1GB

effective_io_concurrency = 150
random_page_cost = 1.1

autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 20s
autovacuum_vacuum_scale_factor = 0.02
autovacuum_analyze_scale_factor = 0.01

max_worker_processes = 2
max_parallel_workers = 2
max_parallel_workers_per_gather = 2

logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_min_duration_statement = 300ms
log_checkpoints = on
log_lock_waits = on
log_file_mode = 0640
log_line_prefix = '%m [%p] %u@%d '
log_connections = on
log_disconnections = on

shared_preload_libraries = 'pg_stat_statements'
track_activity_query_size = 2048

timezone = 'UTC'
```

### 4.7 `config/pg_hba.conf`

```ini
local   all             all                             trust
host    all             all             127.0.0.1/32    md5
host    all             all             10.0.0.0/8      md5
host    all             all             0.0.0.0/0       md5
host    all             all             172.16.0.0/12   md5
```

> Port 5432 is only published on `127.0.0.1`, so there is no external access
> to the DB. In production consider hardening these rules
> (`scram-sha-256`, narrower source networks).

### 4.8 `config/initdb.d/00_extensions.sh`

The `postgres` image runs the files in `/docker-entrypoint-initdb.d`
automatically **only on the first start** (empty datadir). This script creates
`pg_stat_statements` in all non-template DBs and in `template1` (so that the
`zabbix` DB, created afterwards by `zabbix-server`, inherits it):

```sh
#!/bin/sh
# PostgreSQL initialization script.
# Automatically run by docker-entrypoint.sh ONLY the first time the datadir
# (volume ./data/pgsql) is empty (first init).
# Creates the pg_stat_statements extension in all non-template databases and
# in template1, so that any DB created afterwards (e.g. 'zabbix', created by
# zabbix-server) inherits it automatically.
set -e

for db in $(psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"); do
    echo ">> [initdb] CREATE EXTENSION pg_stat_statements in '$db'"
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" \
      -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
done

echo ">> [initdb] CREATE EXTENSION pg_stat_statements in 'template1' (inherited by future DBs)"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d template1 \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

> Give the file execution permission: `chmod +x
> config/initdb.d/00_extensions.sh`.
>
> **Important:** if the datadir already exists (previous deploy), the scripts
> are **not** run again; install the extension manually in that case
> (section 6.6).

### 4.9 File ownership

Services run as `root` inside the container; the files in `/opt/zabbix` are
owned by `root`:

```bash
sudo chown -R root:root /opt/zabbix
```

## 5. Starting the stack

```bash
cd /opt/zabbix
sudo docker compose up -d
```

The first start downloads the images and, **only on first boot**,
`zabbix-server` creates the `zabbix` database and its schema. Wait a few
seconds and check:

```bash
sudo docker compose ps
```

Expected result (all 4 containers up; `zabbix-pgsql` and `zabbix-web` in
`healthy` state):

| NOMBRE        | IMAGE                                          | PORTS                                  |
|---------------|------------------------------------------------|----------------------------------------|
| zabbix-pgsql  | postgres:18-alpine                             | 127.0.0.1:5432->5432/tcp               |
| zabbix-server | zabbix/zabbix-server-pgsql:7.4-alpine-latest   | 0.0.0.0:10051->10051/tcp               |
| zabbix-agent  | zabbix/zabbix-agent:7.4-alpine-latest          | 0.0.0.0:10050->10050/tcp               |
| zabbix-web    | zabbix/zabbix-web-nginx-pgsql:7.4-alpine-latest| 127.0.0.1:8080->8080/tcp, 8443/tcp     |

## 6. Post-installation

1. **Web access:** `http://192.168.20.105:8080` (or `http://localhost:8080`
   from the host itself, since the port only listens on loopback). The DB and
   server boot may take 1–2 minutes.
2. **Initial credentials:** user `Admin`, password `zabbix`.
3. **Change the `Admin` password** (profile → password) and the `postgres`
   one if needed.
4. **Verify the "Zabbix server" host:** in *Monitoring → Latest data* it
   should show data from the local agent (CPU, uptime, network, disk...). If
   items fail, check the agent's `ZBX_HOSTNAME` (step 4.5).

### Final verification

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080          # 200
sudo docker exec zabbix-server zabbix_get -s zabbix-agent -k system.uptime
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -c "SELECT host FROM hosts WHERE status=0;"
```

### pg_stat_statements (automatic)

The extension is preloaded via `shared_preload_libraries` (postgres.conf) and
is **created automatically on first init** thanks to
`config/initdb.d/00_extensions.sh` (see 4.8). On a fresh deploy there is
nothing to do; you can verify it:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -tAc "SELECT extname FROM pg_extension ORDER BY 1;"
# → plpgsql
#   pg_stat_statements
```

Only if you set up an **already-existing** datadir (a previous deploy without
the script), install it manually once:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

## 7. Firewall (UFW)

```bash
# Agents/proxies → Zabbix server
sudo ufw allow from <AGENT_IP>/32 to any port 10050,10051 proto tcp
# If you want the web externally reachable (recommended: behind an HTTPS proxy)
sudo ufw allow from <ADMIN_IP>/32 to any port 8080 proto tcp
```

## 8. Upgrading

```bash
cd /opt/zabbix
sudo docker compose down --remove-orphans          # optional: avoids hot upgrades
# Edit docker-compose.yml with the new image tag (e.g. 7.6-alpine-latest)
sudo docker compose pull
sudo docker compose up -d
```

Before a major upgrade: **backup the DB** (see README → Backup).

## 9. Troubleshooting

* **`dial unix /var/run/docker.sock: connect: permission denied`** → add your
  user to the `docker` group or use `sudo`.
* **`FATAL: database "zabbix" does not exist`** → normal on first start:
  `zabbix-server` creates it automatically.
* **Web staying amber in `docker compose ps`** → check `sudo docker compose
  logs zabbix-web`; usually a startup delay or a misspelled variable.
* **`zabbix-pgsql` not turning `healthy`** → check the healthcheck
  (`pg_isready`) and the postgres log. Until it is `healthy`,
  `zabbix-server`/`zabbix-web` will not start (`condition: service_healthy`).

## 10. References

* [Zabbix: installing via containers](https://www.zabbix.com/documentation/current/manual/installation/containers)
* [zabbix-docker repository (GitHub)](https://github.com/zabbix/zabbix-docker)
* [postgres image on Docker Hub](https://hub.docker.com/_/postgres)
* [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
