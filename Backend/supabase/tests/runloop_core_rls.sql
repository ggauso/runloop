begin;

insert into auth.users (id) values
    ('f1030000-0000-0000-0000-000000000001'),
    ('f1030000-0000-0000-0000-000000000002');

set local role authenticated;
set local request.jwt.claims = '{"sub":"f1030000-0000-0000-0000-000000000001"}';

insert into public.profiles (display_name) values ('Primo runner');
insert into public.routes (id, name, mode, distance_m, geometry, provider)
values ('f1030000-0000-0000-0000-000000000010', 'Anello di prova', 'manual', 125,
    'SRID=4326;LINESTRING(7.42 43.73,7.421 43.731)', 'graphhopper');
insert into public.workouts (id, route_id, started_at, ended_at, active_duration_s, distance_m)
values ('f1030000-0000-0000-0000-000000000020', 'f1030000-0000-0000-0000-000000000010',
    '2026-11-24T08:00:00Z', '2026-11-24T08:01:00Z', 60, 125);
insert into public.workout_points (workout_id, sequence, recorded_at, position, active_elapsed_s)
values ('f1030000-0000-0000-0000-000000000020', 0, '2026-11-24T08:00:00Z', 'SRID=4326;POINT(7.42 43.73)', 0);

do $$
begin
    update public.routes set name = 'Percorso aggiornato', updated_at = '2000-01-01T00:00:00Z'
        where id = 'f1030000-0000-0000-0000-000000000010';
    if not exists (select 1 from public.routes where name = 'Percorso aggiornato' and updated_at > '2000-01-01')
        or not exists (select 1 from public.profiles where id = 'f1030000-0000-0000-0000-000000000001')
        or not exists (select 1 from public.workouts where owner_id = 'f1030000-0000-0000-0000-000000000001')
        or not exists (select 1 from public.workout_points where sequence = 0) then
        raise exception 'Il proprietario non può leggere o modificare i propri dati';
    end if;

    begin
        insert into public.workout_points select * from public.workout_points where sequence = 0;
        raise exception 'La sequenza duplicata è stata accettata';
    exception when unique_violation then
        null;
    end;
end;
$$;

set local request.jwt.claims = '{"sub":"f1030000-0000-0000-0000-000000000002"}';

do $$
begin
    if exists (select 1 from public.profiles)
        or exists (select 1 from public.routes)
        or exists (select 1 from public.workouts)
        or exists (select 1 from public.workout_points) then
        raise exception 'Il secondo utente può leggere dati del primo';
    end if;

    update public.routes set name = 'Alterato' where id = 'f1030000-0000-0000-0000-000000000010';
    if found then raise exception 'Il secondo utente può modificare il percorso'; end if;
    delete from public.workout_points where workout_id = 'f1030000-0000-0000-0000-000000000020';
    if found then raise exception 'Il secondo utente può eliminare i punti'; end if;

    begin
        insert into public.routes (id, owner_id, name, mode, distance_m, geometry, provider)
        values ('f1030000-0000-0000-0000-000000000011', 'f1030000-0000-0000-0000-000000000001',
            'Altrui', 'manual', 10, 'SRID=4326;LINESTRING(7.42 43.73,7.421 43.731)', 'graphhopper');
        raise exception 'Il secondo utente può scrivere a nome del primo';
    exception when insufficient_privilege then
        null;
    end;

    begin
        insert into public.workout_points (workout_id, sequence, recorded_at, position)
        values ('f1030000-0000-0000-0000-000000000020', 1, now(), 'SRID=4326;POINT(7.42 43.73)');
        raise exception 'Il secondo utente può inserire punti nella corsa altrui';
    exception when insufficient_privilege then
        null;
    end;

    begin
        insert into public.workouts (id, route_id, started_at, ended_at, active_duration_s, distance_m)
        values ('f1030000-0000-0000-0000-000000000021', 'f1030000-0000-0000-0000-000000000010', now(), now(), 0, 0);
        raise exception 'È possibile collegare una corsa al percorso di un altro account';
    exception when foreign_key_violation then
        null;
    end;
end;
$$;

insert into public.workouts (id, started_at, ended_at, active_duration_s, distance_m)
values ('f1030000-0000-0000-0000-000000000021', now(), now(), 0, 0);

set local request.jwt.claims = '{"sub":"f1030000-0000-0000-0000-000000000001"}';

do $$
begin
    if (select count(*) from public.workouts) <> 1 then
        raise exception 'Lo storico contiene dati del secondo utente';
    end if;

    delete from public.routes where id = 'f1030000-0000-0000-0000-000000000010';
    if not exists (select 1 from public.workouts where route_id is null and owner_id = 'f1030000-0000-0000-0000-000000000001')
        or not exists (select 1 from public.workout_points) then
        raise exception 'Eliminare un percorso non deve eliminare la corsa o la sua traccia';
    end if;

    delete from public.workouts where id = 'f1030000-0000-0000-0000-000000000020';
    if exists (select 1 from public.workout_points) then
        raise exception 'Eliminare un allenamento deve eliminare i suoi punti';
    end if;
end;
$$;

set local role anon;
set local request.jwt.claims = '{}';

do $$
begin
    if has_table_privilege('public.profiles', 'SELECT, INSERT, UPDATE, DELETE')
        or has_table_privilege('public.routes', 'SELECT, INSERT, UPDATE, DELETE')
        or has_table_privilege('public.workouts', 'SELECT, INSERT, UPDATE, DELETE')
        or has_table_privilege('public.workout_points', 'SELECT, INSERT, UPDATE, DELETE') then
        raise exception 'Il ruolo anon ha privilegi sulle tabelle Runloop';
    end if;
end;
$$;

rollback;
