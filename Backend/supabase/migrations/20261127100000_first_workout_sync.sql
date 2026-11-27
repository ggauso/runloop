begin;

alter table public.workouts add column first_synced_at timestamptz;

-- Older uploads have no completion event. Freeze their last server update as
-- a conservative upper bound, preserving the application's existing timestamps.
alter table public.workouts disable trigger workouts_set_updated_at;
update public.workouts set first_synced_at = updated_at where upload_complete;
alter table public.workouts enable trigger workouts_set_updated_at;

create function runloop_private.capture_first_workout_sync() returns trigger
language plpgsql set search_path = '' as $$
begin
    if tg_op = 'UPDATE' and old.first_synced_at is not null then
        new.first_synced_at := old.first_synced_at;
    elsif new.upload_complete then
        new.first_synced_at := statement_timestamp();
    else
        new.first_synced_at := null;
    end if;
    return new;
end;
$$;
revoke all on function runloop_private.capture_first_workout_sync() from public, anon, authenticated;
create trigger workouts_capture_first_sync before insert or update on public.workouts
    for each row execute function runloop_private.capture_first_workout_sync();

notify pgrst, 'reload schema';
commit;
