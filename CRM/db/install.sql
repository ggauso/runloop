-- Only the launch script runs this as the database owner.
begin;
select pg_advisory_xact_lock(hashtext('runloop_crm.install'));
do $$
begin
    if not exists (select from pg_roles where rolname = 'runloop_crm_reader') then
        create role runloop_crm_reader login nosuperuser nocreatedb nocreaterole nobypassrls;
    end if;
end;
$$;
alter role runloop_crm_reader password :'crm_password';
alter role runloop_crm_reader set default_transaction_read_only = on;

create schema if not exists runloop_crm;
revoke all on schema runloop_crm from public, anon, authenticated, service_role;
grant usage on schema runloop_crm to runloop_crm_reader;

create or replace view runloop_crm.accounts as
select u.id, u.email, nullif(trim(p.display_name), '') as display_name,
       u.created_at as registered_at, u.email_confirmed_at, u.last_sign_in_at
from auth.users u
left join public.profiles p on p.id = u.id
where u.deleted_at is null and u.is_anonymous is not true;

-- Each retained route or completed workout contributes exactly one event.
create or replace view runloop_crm.activity as
select r.owner_id, 'route'::text as kind, r.created_at as occurred_at, null::timestamptz as synced_at
from public.routes r join runloop_crm.accounts a on a.id = r.owner_id
union all
select w.owner_id, 'workout'::text, w.started_at, w.first_synced_at
from public.workouts w join runloop_crm.accounts a on a.id = w.owner_id
where w.upload_complete;

create or replace view runloop_crm.directory as
select a.*, coalesce(s.routes, 0) as routes, coalesce(s.workouts, 0) as workouts,
       s.last_activity_at
from runloop_crm.accounts a
left join (
    select owner_id, count(*) filter (where kind = 'route')::int as routes,
           count(*) filter (where kind = 'workout')::int as workouts, max(occurred_at) as last_activity_at
    from runloop_crm.activity where occurred_at <= now()
    group by owner_id
) s on s.owner_id = a.id;

revoke all on all tables in schema runloop_crm from public, anon, authenticated, service_role;
grant select on runloop_crm.accounts, runloop_crm.activity, runloop_crm.directory to runloop_crm_reader;
commit;
