#!/bin/sh
set -eu
cd "$(dirname "$0")"
if ! docker info >/dev/null 2>&1 && [ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] && docker --context colima info >/dev/null 2>&1; then
    export DOCKER_CONTEXT=colima
fi
if [ ! -f .local/database.env ] || [ -z "$(docker compose -f compose.yaml ps -q crm)" ]; then
    ./start.sh
fi
ticket=$(docker compose -f compose.yaml exec -T crm node server/ticket.js)
url="http://127.0.0.1:4310/#accesso=$ticket"
case "$(uname -s)" in
    Darwin) open "$url" ;;
    *) xdg-open "$url" ;;
esac
