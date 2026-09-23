# Zabbix en Docker (Zabbix + PostgreSQL)

Plataforma de monitorización **Zabbix 7.4** desplegada con Docker Compose sobre
**PostgreSQL 18**, siguiendo el patrón de contenedores oficial de Zabbix:

| Servicio              | Imagen                                     | Versión  |
|-----------------------|--------------------------------------------|----------|
| Base de datos         | `postgres:18-alpine`                       | 18.6     |
| Servidor Zabbix       | `zabbix/zabbix-server-pgsql`               | 7.4.14   |
| Frontend web (nginx)  | `zabbix/zabbix-web-nginx-pgsql`            | 7.4.14   |
| Zabbix Agent (nativo) | `zabbix/zabbix-agent`                      | 7.4.14   |

> Los cuatro contenedores usan la variante **alpine** (imagen ligera basada en
> musl/glibc) y el esquema de base de datos `public` estándar de Zabbix sobre
> PostgreSQL.

---

## Arquitectura

```
                          │ 192.168.20.105  (zabbix-01 · Ubuntu 26.04 LTS)
                          │
        ┌─────────────────┴──────────────────────────┐
        │            Red interna zbx_net             │
        │             (bridge · 172.18.0.0/16)       │
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
        │   │ web (nginx)│    │       ▲ self-    │   │
        │   │  :8080     │    │       │ monitor  │   │
        │   └─────┬──────┘    └───────┴──────────┘   │
        └─────────┼──────────────────────────────────┘
                  │ 127.0.0.1:8080 (solo local)
```

* **zabbix-server** consulta la BD (`pgsql-server`), procesa datos, dispara
  triggers y gestiona la cola de checks.
* **zabbix-agent** monitoriza el propio host *"Zabbix server"* (items de
  CPU, memoria, red, disco…).
* **zabbix-web** expone la interfaz web (nginx + PHP-FPM) en `127.0.0.1:8080`.

---

## Requisitos del host

| Recurso        | Valor                                          |
|----------------|------------------------------------------------|
| SO             | Ubuntu 26.04.1 LTS (kernel 6.x)                |
| CPU            | 4 vCPU (AMD Ryzen 5 5500U)                     |
| Memoria        | 7.2 GiB (el stack reserva 1 GiB pgsql)         |
| Disco          | 54 GiB (≈38 GiB libres)                        |
| Docker Engine  | ≥ 29.x                                         |
| Docker Compose | plugin `docker compose` ≥ 2.x (v5.5.1 en uso)  |

---

## Estructura del proyecto

```
/opt/zabbix
├── docker-compose.yml        # Definición del stack (4 servicios)
├── config/
│   ├── pgsql.env             # Credenciales/inicialización de PostgreSQL
│   ├── postgres.conf         # Configuración de PostgreSQL (tunings)
│   ├── pg_hba.conf           # Reglas de autenticación de acceso a la BD
│   ├── initdb.d/             # Scripts que PostgreSQL ejecuta en el 1er init
│   │   └── 00_extensions.sh  #   → CREATE EXTENSION pg_stat_statements
│   ├── zabbix-server.env     # Conexión BD del servidor Zabbix
│   ├── zabbix-web.env        # Conexión BD + frontend Zabbix
│   └── zabbix-agent.env      # Configuración del agente (hostname, server)
├── data/
│   └── pgsql/                # DATOS PERSISTENTES de PostgreSQL (bind mount)
│       └── 18/docker/        # PGDATA de la instancia
└── README.md                 # Este documento
```

> **Importante:** `data/pgsql` es el almacenamiento permanente de la base de
> datos. No lo borres si quieres conservar el histórico de monitorización. Está
> montado en `/var/lib/postgresql/18/docker` dentro del contenedor.

---

## Puertos expuestos

| Puerto       | Servicio            | Bind                        | Uso                                   |
|--------------|---------------------|-----------------------------|---------------------------------------|
| `8080/tcp`   | zabbix-web          | `127.0.0.1` (solo local)    | Interfaz web Zabbix (HTTP)            |
| `8443/tcp`   | zabbix-web          | interno (contenedor)        | HTTPS (no activo: faltan certificados)|
| `10051/tcp`  | zabbix-server       | `0.0.0.0`                   | Entrada de agents/active proxies      |
| `10050/tcp`  | zabbix-agent        | `0.0.0.0`                   | Consultas del servidor (checks pasivos)|
| `5432/tcp`   | zabbix-pgsql        | `127.0.0.1` (solo local)    | Acceso administrativo a PostgreSQL    |

---

## Credenciales por defecto

| Componente        | Usuario | Contraseña            |
|-------------------|---------|-----------------------|
| Frontend Zabbix   | `Admin` | `zabbix`              |
| PostgreSQL        | `postgres` | definida en `config/pgsql.env` |

> **Cambia la contraseña de `Admin` al momento.** La contraseña de la BD vive
> en los ficheros `config/*.env`; si la modificas, actualízala en **todos** los
> env files y reinicia el stack (los tres servicios comparten credenciales).

---

## Operaciones habituales

Todos los comandos se ejecutan como `sysadmin` en el host (requieren `sudo`
para hablar con el daemon de Docker).

```bash
cd /opt/zabbix

# Levantar el stack
sudo docker compose up -d

# Estado de los contenedores
sudo docker compose ps

# Logs de un servicio concreto
sudo docker compose logs -f zabbix-server

# Reiniciar un servicio
sudo docker compose restart zabbix-server

# Parar todo (los datos persisten en ./data/pgsql)
sudo docker compose down

# Parar y borrar contenedores + red (NO borra data/pgsql)
sudo docker compose down --remove-orphans

# Ver versión y configuración efectiva
sudo docker compose config
```

### Comprobación rápida de salud

```bash
# Todos los contenedores arriba y web/pgsql "healthy"
sudo docker ps --format "table {{.Names}}\t{{.Status}}"

# Estado del healthcheck de PostgreSQL
sudo docker inspect --format "{{.State.Health.Status}}" zabbix-pgsql

# Interfaz web responde
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080     # → 200

# El servidor puede leer métricas del agente local
sudo docker exec zabbix-server zabbix_get -s zabbix-agent -k system.uptime
```

### Acceso a la base de datos

```bash
sudo docker exec -it zabbix-pgsql psql -U postgres -d zabbix
```

Extensiones instaladas en todas las BDs: `plpgsql` y `pg_stat_statements`.
`pg_stat_statements` se activa en `postgres.conf` vía
`shared_preload_libraries` y se **instala automáticamente en el primer
arranque** con el script `config/initdb.d/00_extensions.sh` (lo ejecuta
`docker-entrypoint.sh` solo cuando el datadir está vacío). También se instala
en `template1` para que cualquier BD creada después (como `zabbix`) la herede.

Si arrancas desde un datadir ya existente (creado sin el script), instálala a
mano:

```bash
sudo docker exec zabbix-pgsql psql -U postgres -d postgres -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

---

## Configuración destacada

### `config/postgres.conf`
Parámetros de PostgreSQL standalone (sin modificar el del contenedor):
* Memoria: `shared_buffers=512MB`, `effective_cache_size=1GB`,
  `work_mem=16MB`.
* WAL: `wal_level=replica`, `max_wal_size=2GB`, checkpoints cada 15 min.
* Autovacuum reforzado (4 workers) para tablas de histórico de Zabbix.
* Logs: emails por día a `log/postgresql-%Y-%m-%d.log`, `log_min_duration_statement=300ms`.
* `shared_preload_libraries='pg_stat_statements'`.

### Healthcheck de PostgreSQL
`pgsql-server` expone un healthcheck (`pg_isready -U $POSTGRES_USER -d
postgres`, cada 10 s con `start_period` de 30 s). `zabbix-server` y `zabbix-web`
esperan a que la BD esté **healthy** (`depends_on.condition:
service_healthy`) antes de arrancar, evitando carreras de inicio. Estado
visible con `sudo docker ps --format "{{.Names}} {{.Status}}"`.

### `config/pg_hba.conf`
Reglas de acceso: `trust` en socket local, `md5` para 127.0.0.1, 10/8,
172.16/12 (riesgo interno docker) y 0.0.0.0/0. El puerto solo está publicado
en **127.0.0.1**, así que el acceso externo queda bloqueado a nivel de Docker.

### `config/*.env`
Variables de credenciales y conexión. El fichero web/apunta al servidor y a la
BD por nombre de contenedor (resolución por DNS de Docker).

### `config/initdb.d/`
Montado en `/docker-entrypoint-initdb.d`, es el mecanismo estándar de la
imagen `postgres` para ejecutar scripts **solo en el primer init** (datadir
vacío). Aquí se crea la extensión `pg_stat_statements`. Un datadir ya
existente **nunca** los vuelve a ejecutar.

---

## Actualización del stack (upgrade)

1. Haz una copia de la BD (ver más abajo).
2. Sube el tag de las imágenes en `docker-compose.yml` (ej. `7.4-alpine-latest`
   → `7.6-alpine-latest`).
3. `sudo docker compose pull && sudo docker compose up -d`
4. Verifica que el servidor reporta la nueva versión:
   `sudo docker logs zabbix-server 2>&1 | grep "current database version"`.

> Zabbix aplica sus propios cambios de esquema al arrancar. En versiones
> mayores lee primero las notas de compatibilidad de la BD.

---

## Backup y restauración

### Backup lógico (pg_dump)

```bash
# Dump de la BD "zabbix"
sudo docker exec zabbix-pgsql pg_dump -U postgres -d zabbix -Fc -f /tmp/zabbix.dump
sudo docker cp zabbix-pgsql:/tmp/zabbix.dump ~/zabbix-$(date +%F).dump

# Dump nativo de PostgreSQL (datos + esquema SQL)
sudo docker exec zabbix-pgsql pg_dumpall -U postgres > ~/pgdumpall-$(date +%F).sql
```

> La forma más sencilla de "snapshot" completo es copiar el directorio
> `data/pgsql` con el servicio parado (copy-out de PGDATA).

### Restauración

```bash
sudo docker cp ~/zabbix.dump zabbix-pgsql:/tmp/
sudo docker exec zabbix-pgsql pg_restore -U postgres -d zabbix \
  --clean --if-exists /tmp/zabbix.dump
```

---

## Seguridad

* La web solo escucha en `127.0.0.1` — si necesitas acceso externo, publica el
  puerto y usa HTTPS (el contenedor intenta cargar certificados en
  `/etc/ssl/nginx`; sin ellos arranca en HTTP).
* Los puertos `10050`/`10051` están abiertos a toda interface: recínfalos a las
  IP de tus agents en el firewall (`ufw allow from <agent_ip> to any port
  10050,10051 proto tcp`).
* `pg_hba.conf` acepta `md5` desde cualquier host (`0.0.0.0/0`): considera
  `scram-sha-256` y acotar la red de origen si no es un entorno de laboratorio.
* Cambia las contraseñas por defecto (`Admin/zabbix` y la de `postgres`).

---

## Troubleshooting

| Síntoma                                        | Causa probable / solución                                   |
|------------------------------------------------|-------------------------------------------------------------|
| Web responde pero "Database is not initialized"| Espera a que `zabbix-server` cree el esquema; revisa `docker logs zabbix-server` |
| `FATAL: database "zabbix" does not exist`      | El server aún no ha creado la BD (primer arranque)          |
| Items del host "Zabbix server" en rojo         | El agente no registra: revisa `config/zabbix-agent.env` (`ZBX_HOSTNAME` debe coincidir con el host "Zabbix server") |
| Warning *"1024 file descriptors insufficient"* | Ya corregido: `ulimits.nofile` = 65536 en el compose        |
| Contraseña de BD: `FATAL: password authentication failed` | Cambiaste la pass solo en un env file; actualiza `config/pgsql.env`, `zabbix-server.env` y `zabbix-web.env` |
| `dial unix /var/run/docker.sock` denegado      | Ejecuta con `sudo` (grupo `docker` no otorgado a sysadmin)  |

---

## Referencias

* [Zabbix docs — docker containers](https://www.zabbix.com/documentation/current/manual/installation/containers)
* [Zabbix Docker images (GitHub)](https://github.com/zabbix/zabbix-docker)
* [Registro de imágenes Zabbix](https://hub.docker.com/u/zabbix)
* [Documentación PostgreSQL](https://www.postgresql.org/docs/current/runtime-config.html)
