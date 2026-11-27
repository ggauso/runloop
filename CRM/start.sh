#!/bin/sh
set -eu
cd "$(dirname "$0")"
umask 077
# Follow the chosen Docker context. A common macOS installation runs in Colima.
if ! docker info >/dev/null 2>&1 && [ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] && docker --context colima info >/dev/null 2>&1; then
    export DOCKER_CONTEXT=colima
fi
backend() ( cd ../Backend/supabase && docker compose -f docker-compose.yml "$@" )
db_id=$(backend ps -q db)
if [ -z "$db_id" ]; then
    echo "Avvia il database Supabase di Runloop prima del CRM." >&2
    exit 1
fi
project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$db_id")
export RUNLOOP_CRM_NETWORK="${RUNLOOP_CRM_NETWORK:-${project}_default}"
RUNLOOP_CRM_DATABASE=$(backend exec -T db sh -c 'printf %s "${POSTGRES_DB:-postgres}"')
export RUNLOOP_CRM_DATABASE
mkdir -p .local
if [ ! -f .local/database.env ]; then
    temp=$(mktemp .local/database.XXXXXX)
    trap 'rm -f "$temp"' EXIT
    password=$(openssl rand -hex 32)
    printf 'PGPASSWORD=%s\n' "$password" > "$temp"
    ln "$temp" .local/database.env || test -s .local/database.env
fi
password=$(sed -n 's/^PGPASSWORD=//p' .local/database.env)
if ! printf '%s\n' "$password" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'; then
    echo "Credenziale CRM locale non valida in .local/database.env." >&2
    exit 1
fi
{
    printf "\\\\set crm_password '%s'\n" "$password"
    cat db/install.sql
} | backend exec -T db psql -Xq -U postgres -d "$RUNLOOP_CRM_DATABASE" -v ON_ERROR_STOP=1 > /dev/null
docker compose -f compose.yaml up -d --build --wait crm
echo "Runloop CRM è disponibile su http://127.0.0.1:4310"
