begin;

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

create schema runloop_private;
revoke all on schema runloop_private from public, anon, authenticated;
grant usage on schema runloop_private to authenticated, service_role;

-- The Compose database image ships a legacy auth.uid(); PostgREST sends JSON claims.
create function runloop_private.request_user_id() returns uuid
language sql stable set search_path = '' as $$
    select coalesce(
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid,
        auth.uid()
    );
$$;

revoke all on function runloop_private.request_user_id() from public, anon, authenticated;
grant execute on function runloop_private.request_user_id() to authenticated, service_role;

create function runloop_private.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
    new.updated_at := statement_timestamp();
    return new;
end;
$$;

revoke all on function runloop_private.set_updated_at() from public, anon, authenticated;

create table public.profiles (
    id uuid primary key default runloop_private.request_user_id() references auth.users (id) on delete cascade,
    display_name text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table public.routes (
    id uuid primary key,
    owner_id uuid not null default runloop_private.request_user_id() references auth.users (id) on delete cascade,
    name text not null check (length(btrim(name)) > 0),
    mode text not null,
    target_distance_m integer,
    distance_m double precision not null check (distance_m > 0 and distance_m < 'Infinity'::double precision),
    waypoints jsonb not null default '[]'::jsonb check (jsonb_typeof(waypoints) = 'array'),
    geometry extensions.geometry(LineString, 4326) not null,
    provider text not null check (length(btrim(provider)) > 0),
    revision integer not null default 1 check (revision > 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (owner_id, id),
    constraint routes_mode_target_check check (
        (mode = 'manual' and target_distance_m is null)
        or (mode = 'round_trip' and target_distance_m is not null and target_distance_m > 0)
    ),
    constraint routes_geometry_check check (
        extensions.st_npoints(geometry) >= 2
        and extensions.st_xmin(geometry) >= -180 and extensions.st_xmax(geometry) <= 180
        and extensions.st_ymin(geometry) >= -90 and extensions.st_ymax(geometry) <= 90
    )
);

create table public.workouts (
    id uuid primary key,
    owner_id uuid not null default runloop_private.request_user_id() references auth.users (id) on delete cascade,
    route_id uuid,
    healthkit_workout_uuid uuid,
    started_at timestamptz not null,
    ended_at timestamptz not null,
    active_duration_s integer not null check (active_duration_s >= 0),
    distance_m double precision not null check (distance_m >= 0 and distance_m < 'Infinity'::double precision),
    avg_pace_s_per_km double precision check (avg_pace_s_per_km > 0 and avg_pace_s_per_km < 'Infinity'::double precision),
    avg_heart_rate_bpm double precision check (avg_heart_rate_bpm > 0 and avg_heart_rate_bpm < 'Infinity'::double precision),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint workouts_interval_check check (ended_at >= started_at),
    constraint workouts_route_owner_fk foreign key (owner_id, route_id)
        references public.routes (owner_id, id) on delete set null (route_id)
);

create table public.workout_points (
    workout_id uuid not null references public.workouts (id) on delete cascade,
    sequence integer not null check (sequence >= 0),
    recorded_at timestamptz not null,
    position extensions.geometry(Point, 4326) not null,
    active_elapsed_s integer check (active_elapsed_s >= 0),
    speed_mps double precision check (speed_mps >= 0 and speed_mps < 'Infinity'::double precision),
    primary key (workout_id, sequence),
    constraint workout_points_position_check check (
        not extensions.st_isempty(position)
        and extensions.st_x(position) between -180 and 180
        and extensions.st_y(position) between -90 and 90
    )
);

create index workouts_owner_started_idx on public.workouts (owner_id, started_at desc);
create index workouts_route_owner_idx on public.workouts (route_id, owner_id) where route_id is not null;

create trigger profiles_set_updated_at before update on public.profiles
    for each row execute function runloop_private.set_updated_at();
create trigger routes_set_updated_at before update on public.routes
    for each row execute function runloop_private.set_updated_at();
create trigger workouts_set_updated_at before update on public.workouts
    for each row execute function runloop_private.set_updated_at();

alter table public.profiles enable row level security;
alter table public.routes enable row level security;
alter table public.workouts enable row level security;
alter table public.workout_points enable row level security;

revoke all on public.profiles, public.routes, public.workouts, public.workout_points
    from public, anon, authenticated;
grant select, insert, update, delete on public.profiles, public.routes, public.workouts, public.workout_points
    to authenticated, service_role;

create policy profiles_owner on public.profiles for all to authenticated
    using (id = (select runloop_private.request_user_id()))
    with check (id = (select runloop_private.request_user_id()));

create policy routes_owner on public.routes for all to authenticated
    using (owner_id = (select runloop_private.request_user_id()))
    with check (owner_id = (select runloop_private.request_user_id()));

create policy workouts_owner on public.workouts for all to authenticated
    using (owner_id = (select runloop_private.request_user_id()))
    with check (owner_id = (select runloop_private.request_user_id()));

create policy workout_points_owner on public.workout_points for all to authenticated
    using (exists (
        select 1 from public.workouts as workout
        where workout.id = workout_points.workout_id
            and workout.owner_id = (select runloop_private.request_user_id())
    ))
    with check (exists (
        select 1 from public.workouts as workout
        where workout.id = workout_points.workout_id
            and workout.owner_id = (select runloop_private.request_user_id())
    ));

notify pgrst, 'reload schema';

commit;
