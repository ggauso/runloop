#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Match the Runloop Compose image. No ports, external networks or application volumes.
instance=$(docker run -d --rm --network none -e POSTGRES_PASSWORD=fixture supabase/postgres:17.6.1.136)
trap 'docker stop "$instance" >/dev/null' EXIT
query() { docker exec -i "$instance" psql -Xq -d postgres -v ON_ERROR_STOP=1 -U "$1"; }
tries=0
until docker exec "$instance" pg_isready -h 127.0.0.1 -q -U postgres; do
    tries=$((tries + 1))
    if [ "$tries" -ge 45 ]; then echo "Database di prova non disponibile" >&2; exit 1; fi
    sleep 1
done
# The bare database image predates these columns installed by Supabase Auth.
query supabase_admin <<'SQL'
alter table auth.users add column if not exists email_confirmed_at timestamptz,
    add column if not exists deleted_at timestamptz,
    add column if not exists is_anonymous boolean default false,
    add column if not exists is_sso_user boolean default false;
SQL
for migration in ../Backend/supabase/migrations/*.sql; do
    if [ "${migration##*/}" = 20261127100000_first_workout_sync.sql ]; then
        # One completed upload predates the migration and lands exactly at the deadline.
        query supabase_admin <<'SQL'
begin;
insert into auth.users (id, created_at) values ('81fa2253-0000-4000-8000-000000000001', now() - interval '192 hours');
insert into public.workouts (id, owner_id, started_at, ended_at, active_duration_s, distance_m, updated_at)
select '81fa2253-0000-4000-8000-000000000011', id, created_at, created_at, 0, 0, created_at + interval '168 hours'
from auth.users where id = '81fa2253-0000-4000-8000-000000000001';
commit;
SQL
    fi
    query postgres < "$migration"
done
{ printf "%s\n" "\\set crm_password 'fixture'"; cat db/install.sql; } | query postgres
{
    printf '%s\n' 'begin;' "set local time zone 'Europe/Rome';" 'prepare crm_overview(int) as'
    cat db/overview.sql
    printf '%s\n' 'prepare crm_users(text,text,int,int) as'
    cat db/users.sql tests/data.sql
} | query supabase_admin
{
    printf '%s\n' "set time zone 'Europe/Rome';" 'prepare crm_overview(int) as'
    cat db/overview.sql tests/first-sync.sql
} | query supabase_admin
echo "Verificati conteggi, ricerca e permessi su un database temporaneo."
