begin;

insert into auth.users (id) values
    ('f4020000-0000-0000-0000-000000000001'),
    ('f4020000-0000-0000-0000-000000000002');

set local role authenticated;
set local request.jwt.claims = '{"sub":"f4020000-0000-0000-0000-000000000001"}';

do $$
declare
    owner uuid := 'f4020000-0000-0000-0000-000000000001';
    workout uuid := 'f4020000-0000-0000-0000-000000000010';
    summary jsonb := '{
        "id": "f4020000-0000-0000-0000-000000000010", "point_count": 2,
        "route_id": "f4020000-0000-0000-0000-000000000020",
        "started_at": "2026-11-24T08:00:00Z", "ended_at": "2026-11-24T08:01:00Z",
        "active_duration_s": 50, "distance_m": 125, "avg_pace_s_per_km": 400
    }';
    first_point jsonb := '[{"sequence":0,"recorded_at":"2026-11-24T08:00:05Z","longitude":7.42,"latitude":43.73,"active_elapsed_s":5}]';
    second_point jsonb := '[{"sequence":1,"recorded_at":"2026-11-24T08:00:25Z","longitude":7.421,"latitude":43.731,"active_elapsed_s":15}]';
begin
    perform public.upload_workout_batch(owner, summary, first_point, false);
    if (select upload_complete from public.workouts where id = workout) is distinct from false then
        raise exception 'Partial upload was not marked incomplete';
    end if;
    begin
        perform public.upload_workout_batch(owner, summary, first_point, true);
        raise exception 'Upload finalized with points missing';
    exception when invalid_parameter_value then
        null;
    end;
    perform public.upload_workout_batch(owner, summary, second_point, true);
    perform public.upload_workout_batch(owner, summary, first_point || second_point, true);
    if (select count(*) from public.workout_points where workout_id = workout) <> 2
        or not exists (select 1 from public.workouts where id = workout and upload_complete
                       and route_id is null and avg_heart_rate_bpm is null and healthkit_workout_uuid is null) then
        raise exception 'Replay duplicated or changed the workout';
    end if;
end;
$$;

set local request.jwt.claims = '{"sub":"f4020000-0000-0000-0000-000000000002"}';

do $$
begin
    if exists (select 1 from public.workouts where id = 'f4020000-0000-0000-0000-000000000010')
        or exists (select 1 from public.workout_points where workout_id = 'f4020000-0000-0000-0000-000000000010') then
        raise exception 'An unrelated account can read the workout';
    end if;
    begin
        perform public.upload_workout_batch('f4020000-0000-0000-0000-000000000001', '{}', '[]', true);
        raise exception 'An unrelated account can upload on behalf of the owner';
    exception when insufficient_privilege then
        null;
    end;
    begin
        perform public.delete_recorded_workout('f4020000-0000-0000-0000-000000000001', 'f4020000-0000-0000-0000-000000000010');
        raise exception 'An unrelated account can delete on behalf of the owner';
    exception when insufficient_privilege then
        null;
    end;
end;
$$;

set local request.jwt.claims = '{"sub":"f4020000-0000-0000-0000-000000000001"}';

do $$
declare
    owner uuid := 'f4020000-0000-0000-0000-000000000001';
    workout uuid := 'f4020000-0000-0000-0000-000000000010';
    summary jsonb := '{
        "id": "f4020000-0000-0000-0000-000000000010", "point_count": 0,
        "started_at": "2026-11-24T08:00:00Z", "ended_at": "2026-11-24T08:01:00Z",
        "active_duration_s": 50, "distance_m": 125
    }';
begin
    perform public.delete_recorded_workout(owner, workout);
    perform public.delete_recorded_workout(owner, workout);
    if exists (select 1 from public.workouts where id = workout)
        or exists (select 1 from public.workout_points where workout_id = workout) then
        raise exception 'Deletion did not remove the workout and points';
    end if;
    begin
        perform public.upload_workout_batch(owner, summary, '[]', true);
        raise exception 'Retry recreated a deleted workout';
    exception when invalid_parameter_value then
        null;
    end;
end;
$$;

rollback;
