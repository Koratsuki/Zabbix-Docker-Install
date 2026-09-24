# INSTALL — Instalación de Zabbix (contenedores Docker) sobre Ubuntu

Guía paso a paso para desplegar el stack **Zabbix 7.4 + PostgreSQL 18** con
Docker Compose. Referencia del entorno de pruebas incluida: host
`zabbix-01` (192.168.20.105), Ubuntu 26.04 LTS.

---

## 1. Requisitos previos

* Ubuntu 22.04 o superior (probado en 26.04.1 LTS).
* Usuario con `sudo` (en este entorno: `sysadmin`).
* Mínimo recomendado: 2 CPU, 4 GiB RAM, 20 GiB de disco libre.

```bash
sudo apt update && sudo apt upgrade -y
```

## 2. Instalar Docker Engine y el plugin de Compose

Instala Docker desde el repositorio oficial de Docker (no el paquete de Ubuntu):

```bash
# Paquetes previos
sudo apt install -y ca-certificates curl

# Clave y repositorio de Docker
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalar
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

> Tu distribución (`$(VERSION_CODENAME)`) debe estar soportada por Docker;
> en Ubuntu 26.04 usa `noble` si el codename no está publicado todavía.

Añade tu usuario al grupo `docker` para no usar `sudo` en cada comando
(opcional; en esta instalación se usa `sudo`):

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

Verifica:

```bash
sudo docker run --rm hello-world
docker compose version    # → Docker Compose version v2.x+ (usada: v5.5.1)
```

## 3. Crear la estructura de directorios

```bash
sudo mkdir -p /opt/zabbix/{config,data/pgsql}
```

A partir de aquí se asume que todos los ficheros del proyecto viven en
`/opt/zabbix` (docker-compose.yml, config/, data/).

## 4. Escritura de los ficheros del proyecto

Crea cada fichero listado abajo. Los `.env` comparten las **mismas
credenciales** de PostgreSQL (en este despliegue el usuario es `postgres` y la
BD de Zabbix se llama `zabbix`).

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

> No uses sintaxis `VARIABLE: valor` en los env files: el formato válido de
> Docker Compose es `VARIABLE=valor`.
>
> El volumen `./config/initdb.d:/docker-entrypoint-initdb.d:ro` es el que
> automatiza la creación de extensiones (ver 4.8).

### 4.2 `config/pgsql.env`

```ini
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<LA_MISMA_PASS_EN_TODOS>
TZ=UTC
```

### 4.3 `config/zabbix-server.env`

```ini
DB_SERVER_HOST=pgsql-server
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<LA_MISMA_PASS_EN_TODOS>
POSTGRES_DB=zabbix
```

### 4.4 `config/zabbix-web.env`

```ini
DB_SERVER_HOST=pgsql-server
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<LA_MISMA_PASS_EN_TODOS>
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

> `ZBX_HOSTNAME` debe coincidir exactamente con el nombre del host que el
> servidor crea automáticamente ("Zabbix server"); si no, los items del
> host propio quedan en estado "Not supported".

### 4.6 `config/postgres.conf`

Tuning de PostgreSQL (falta paramétrico para Zabbix): memoria, WAL,
autovacuum y logging. Contenido de referencia en el deploy:

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

> El puerto 5432 solo se publica en `127.0.0.1`, por lo que no hay acceso
> externo a la BD. En producción valora endurecer estas reglas
> (`scram-sha-256`, acotar redes).

### 4.8 `config/initdb.d/00_extensions.sh`

La imagen `postgres` ejecuta automáticamente los ficheros de
`/docker-entrypoint-initdb.d` **solo en el primer arranque** (datadir vacío).
Este script crea `pg_stat_statements` en todas las BDs no-template y en
`template1` (para que la BD `zabbix`, que `zabbix-server` crea después, la
herede):

```sh
#!/bin/sh
# Script de inicialización de PostgreSQL.
# Se ejecuta automáticamente por docker-entrypoint.sh SOLO la primera vez
# que el datadir (volume ./data/pgsql) está vacío (primer init).
# Crea la extensión pg_stat_statements en todas las bases no-template y en
# template1, para que cualquier BD creada después (p.ej. 'zabbix', creada por
# zabbix-server) la herede automáticamente.
set -e

for db in $(psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"); do
    echo ">> [initdb] CREATE EXTENSION pg_stat_statements en '$db'"
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" \
      -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
done

echo ">> [initdb] CREATE EXTENSION pg_stat_statements en 'template1' (la heredarán futuras BDs)"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d template1 \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

> Da permiso de ejecución al fichero: `chmod +x
> config/initdb.d/00_extensions.sh`.
>
> **Importante:** si el datadir ya existe (deploy previo), los scripts **no** se
> vuelven a ejecutar; instala la extensión a mano en ese caso (sección 6.6).

### 4.9 Propiedades de los ficheros

Los servicios se lanzan como `root` en el contenedor; los ficheros de
`/opt/zabbix` son propiedad de `root`:

```bash
sudo chown -R root:root /opt/zabbix
```

## 5. Arranque del stack

```bash
cd /opt/zabbix
sudo docker compose up -d
```

El primer arranque descarga las imágenes y, en el **primer inicio sólamente**,
`zabbix-server` crea la base de datos `zabbix` y su esquema. Espera unos
segundos y comprueba:

```bash
sudo docker compose ps
```

Resultado esperado (los 4 contenedores arriba; `zabbix-pgsql` y `zabbix-web`
en estado `healthy`):

| NOMBRE         | IMAGEN                                          | PORTS                                  |
|----------------|-------------------------------------------------|----------------------------------------|
| zabbix-pgsql   | postgres:18-alpine                              | 127.0.0.1:5432->5432/tcp               |
| zabbix-server  | zabbix/zabbix-server-pgsql:7.4-alpine-latest    | 0.0.0.0:10051->10051/tcp               |
| zabbix-agent   | zabbix/zabbix-agent:7.4-alpine-latest           | 0.0.0.0:10050->10050/tcp               |
| zabbix-web     | zabbix/zabbix-web-nginx-pgsql:7.4-alpine-latest | 127.0.0.1:8080->8080/tcp, 8443/tcp     |

## 6. Post-instalación

1. **Acceso a la web:** `http://192.168.20.105:8080` (o `http://localhost:8080`
   desde el propio host, ya que el puerto solo escucha en loopback). El
   arranque de la BD/servidor puede tardar 1–2 minutos.
2. **Credenciales iniciales:** usuario `Admin`, contraseña `zabbix`.
3. **Cambia la contraseña** de `Admin` (perfil → contraseña) y la de
   `postgres` si es necesario.
4. **Verifica el host "Zabbix server":** en *Monitoring → Latest data* debe
   mostrar datos del agente local (CPU, uptime, red, disco…). Si los items
   fallan, revisa `ZBX_HOSTNAME` del agente (paso 4.5).

### Verificación final

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080          # 200
sudo docker exec zabbix-server zabbix_get -s zabbix-agent -k system.uptime
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -c "SELECT host FROM hosts WHERE status=0;"
```

### pg_stat_statements (automático)

La extensión se precarga vía `shared_preload_libraries` (postgres.conf) y se
**crea sola en el primer init** gracias a `config/initdb.d/00_extensions.sh`
(ver 4.8). En un deploy nuevo no hay que hacer nada; lo puedes comprobar:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -tAc "SELECT extname FROM pg_extension ORDER BY 1;"
# → plpgsql
#   pg_stat_statements
```

Solo si aparece un datadir **ya existente** (deploy anterior sin el script),
instálala a mano una vez:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d zabbix \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

## 7. Firewall (UFW)

```bash
# Agents/proxies → servidor Zabbix
sudo ufw allow from <IP_AGENT>/32 to any port 10050,10051 proto tcp
# Si quieres la web accesible externamente (recomendado: detrás de proxy con HTTPS)
sudo ufw allow from <IP_ADMIN>/32 to any port 8080 proto tcp
```

## 8. Actualización (upgrade)

```bash
cd /opt/zabbix
sudo docker compose down --remove-orphans          # opcional: evita upgrades en caliente
# Edita docker-compose.yml con la nueva etiqueta de imagen (ej. 7.6-alpine-latest)
sudo docker compose pull
sudo docker compose up -d
```

Antes de un upgrade mayor: **backup de la BD** (ver README → Backup).

## 9. Solución de problemas

* **`dial unix /var/run/docker.sock: connect: permission denied`** → añade tu
  usuario al grupo `docker` o usa `sudo`.
* **`FATAL: database "zabbix" does not exist`** → normal en el primer arranque:
  `zabbix-server` la crea automáticamente.
* **Web en amarillo en `docker compose ps`** → revisa `sudo docker compose logs
  zabbix-web`; suele ser retardo de arranque o variable mal definida.
* **`zabbix-pgsql` sin pasar a `healthy`** → comprueba el healthcheck
  (`pg_isready`) y el log de postgres. Mientras no esté `healthy`,
  `zabbix-server`/`zabbix-web` no arrancarán (`condition: service_healthy`).

## 10. Referencias

* [Zabbix: instalación vía contenedores](https://www.zabbix.com/documentation/current/manual/installation/containers)
* [Repositorio zabbix-docker (GitHub)](https://github.com/zabbix/zabbix-docker)
* [Imagen postgres en Docker Hub](https://hub.docker.com/_/postgres)
* [Instalar Docker Engine en Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
