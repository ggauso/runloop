begin;

create table public.workout_deletions (
    owner_id uuid not null references auth.users (id) on delete cascade,
    workout_id uuid not null,
    primary key (owner_id, workout_id)
);

alter table public.workout_deletions enable row level security;
revoke all on public.workout_deletions from public, anon, authenticated;
grant select, insert on public.workout_deletions to authenticated, service_role;

create policy workout_deletions_owner on public.workout_deletions for all to authenticated
    using (owner_id = (select runloop_private.request_user_id()))
    with check (owner_id = (select runloop_private.request_user_id()));

create function runloop_private.prevent_workout_recreation() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.id::text, 0));
    if exists (
        select 1 from public.workout_deletions as removed
        where removed.owner_id = new.owner_id and removed.workout_id = new.id
    ) then
        raise exception 'Workout has been deleted' using errcode = '22023';
    end if;
    return new;
end;
$$;

revoke all on function runloop_private.prevent_workout_recreation() from public, anon, authenticated;
create trigger prevent_workout_recreation before insert on public.workouts
    for each row execute function runloop_private.prevent_workout_recreation();

create function public.delete_recorded_workout(p_owner uuid, p_id uuid) returns void
language plpgsql security invoker set search_path = '' as $$
begin
    if p_owner is null or p_id is null or p_owner is distinct from runloop_private.request_user_id() then
        raise exception 'Deletion owner does not match the active account' using errcode = '42501';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_id::text, 0));
    insert into public.workout_deletions (owner_id, workout_id) values (p_owner, p_id) on conflict do nothing;
    delete from public.workouts where id = p_id and owner_id = p_owner;
end;
$$;

revoke all on function public.delete_recorded_workout(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_recorded_workout(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
