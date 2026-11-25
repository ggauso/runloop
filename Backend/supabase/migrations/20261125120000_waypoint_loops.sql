begin;

alter table public.routes
    drop constraint routes_mode_target_check,
    add constraint routes_mode_target_check check (
        (mode = 'manual' and target_distance_m is null)
        or (mode = 'round_trip' and target_distance_m is not null and target_distance_m > 0)
        or (mode = 'waypoint_loop' and target_distance_m is null
            and case when jsonb_typeof(waypoints) = 'array' then jsonb_array_length(waypoints) >= 2 else false end
            and extensions.st_isclosed(geometry))
    );

notify pgrst, 'reload schema';

commit;
