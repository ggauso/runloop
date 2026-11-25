begin;

create table runloop_private.routing_quota (
    user_id uuid primary key references auth.users (id) on delete cascade,
    window_start timestamptz not null,
    requests integer not null check (requests between 1 and 12)
);

create function public.runloop_consume_routing_quota(p_user_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
    current_window timestamptz := date_bin('1 minute', statement_timestamp(), '2000-01-01 00:00:00Z');
    accepted boolean;
begin
    insert into runloop_private.routing_quota as quota (user_id, window_start, requests)
    values (p_user_id, current_window, 1)
    on conflict (user_id) do update
    set window_start = excluded.window_start,
        requests = case when quota.window_start < excluded.window_start then 1 else quota.requests + 1 end
    where quota.window_start < excluded.window_start
       or (quota.window_start = excluded.window_start and quota.requests < 12)
    returning true into accepted;

    return coalesce(accepted, false);
end;
$$;

revoke all on function public.runloop_consume_routing_quota(uuid) from public, anon, authenticated;
grant execute on function public.runloop_consume_routing_quota(uuid) to service_role;

notify pgrst, 'reload schema';

commit;
