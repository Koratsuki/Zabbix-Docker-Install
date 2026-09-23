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