begin;

alter table public.workouts add column upload_complete boolean not null default true;

create function public.upload_workout_batch(
    p_owner uuid,
    p_workout jsonb,
    p_points jsonb,
    p_final boolean
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_workout_id uuid := (p_workout ->> 'id')::uuid;
    requested_route_id uuid := (p_workout ->> 'route_id')::uuid;
    route_for_workout uuid;
    expected_points integer := (p_workout ->> 'point_count')::integer;
    valid_points integer;
begin
    if p_owner is null or p_owner is distinct from runloop_private.request_user_id() then
        raise exception 'Upload owner does not match the active account' using errcode = '42501';
    end if;
    if v_workout_id is null or expected_points is null or expected_points not between 0 and 200000
        or jsonb_typeof(p_points) is distinct from 'array' or jsonb_array_length(p_points) > 500 then
        raise exception 'Invalid workout batch' using errcode = '22023';
    end if;

    select route.id into route_for_workout
    from public.routes as route
    where route.owner_id = p_owner and route.id = requested_route_id
    for key share;

    insert into public.workouts (
        id, owner_id, route_id, healthkit_workout_uuid, started_at, ended_at,
        active_duration_s, distance_m, avg_pace_s_per_km, avg_heart_rate_bpm, upload_complete
    )
    values (
        v_workout_id, p_owner, route_for_workout, (p_workout ->> 'healthkit_workout_uuid')::uuid,
        (p_workout ->> 'started_at')::timestamptz, (p_workout ->> 'ended_at')::timestamptz,
        (p_workout ->> 'active_duration_s')::integer, (p_workout ->> 'distance_m')::double precision,
        (p_workout ->> 'avg_pace_s_per_km')::double precision,
        (p_workout ->> 'avg_heart_rate_bpm')::double precision, false
    )
    on conflict (id) do update set
        route_id = excluded.route_id,
        healthkit_workout_uuid = excluded.healthkit_workout_uuid,
        avg_heart_rate_bpm = excluded.avg_heart_rate_bpm;

    if exists (
        select 1 from jsonb_array_elements(p_points) as point(value)
        where (point.value ->> 'sequence')::integer not between 0 and expected_points - 1
    ) then
        raise exception 'Invalid workout sequence' using errcode = '22023';
    end if;

    insert into public.workout_points (workout_id, sequence, recorded_at, position, active_elapsed_s, speed_mps)
    select v_workout_id, point.sequence, point.recorded_at,
           extensions.st_setsrid(extensions.st_makepoint(point.longitude, point.latitude), 4326),
           point.active_elapsed_s, point.speed_mps
    from jsonb_to_recordset(p_points) as point(
        sequence integer, recorded_at timestamptz, longitude double precision, latitude double precision,
        active_elapsed_s integer, speed_mps double precision
    )
    on conflict on constraint workout_points_pkey do nothing;

    if p_final then
        select count(*) into valid_points
        from public.workout_points as stored
        where stored.workout_id = v_workout_id and stored.sequence between 0 and expected_points - 1;
        if valid_points <> expected_points then
            raise exception 'Workout has missing points' using errcode = '22023';
        end if;

        update public.workouts as stored set upload_complete = true
        where stored.id = v_workout_id and stored.owner_id = p_owner;
    end if;
end;
$$;

revoke all on function public.upload_workout_batch(uuid, jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.upload_workout_batch(uuid, jsonb, jsonb, boolean) to authenticated;

notify pgrst, 'reload schema';

commit;
