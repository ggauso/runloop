begin;

insert into auth.users (id) values ('f2050000-0000-0000-0000-000000000001');
set local role authenticated;
set local request.jwt.claims = '{"sub":"f2050000-0000-0000-0000-000000000001"}';

insert into public.routes (id, name, mode, distance_m, geometry, provider)
values ('f2050000-0000-0000-0000-000000000010', 'Prima versione', 'manual', 125,
    'SRID=4326;LINESTRING(7.42 43.73,7.421 43.731)', 'graphhopper');

do $$
declare
    current_revision integer;
begin
    update public.routes set name = 'Rinominato', revision = 99
    where id = 'f2050000-0000-0000-0000-000000000010' returning revision into current_revision;
    if current_revision is distinct from 1 then
        raise exception 'La rinomina non deve cambiare la revisione';
    end if;

    update public.routes set geometry = 'SRID=4326;LINESTRING(7.42 43.73,7.421 43.731,7.423 43.733)'
    where id = 'f2050000-0000-0000-0000-000000000010' returning revision into current_revision;
    if current_revision is distinct from 2 then
        raise exception 'La geometria modificata deve far avanzare la revisione di uno';
    end if;

    begin
        update public.routes set mode = 'waypoint_loop', waypoints = '[{},{}]'
        where id = 'f2050000-0000-0000-0000-000000000010';
        raise exception 'Una geometria aperta non può essere salvata come anello';
    exception when check_violation then
        null;
    end;

    update public.routes set mode = 'waypoint_loop',
        waypoints = '[{"longitude":7.42,"latitude":43.73},{"longitude":7.421,"latitude":43.731}]',
        geometry = 'SRID=4326;LINESTRING(7.42 43.73,7.421 43.731,7.423 43.733,7.42 43.73)'
    where id = 'f2050000-0000-0000-0000-000000000010' returning revision into current_revision;
    if current_revision is distinct from 3 then
        raise exception 'La conversione in un anello deve essere salvata con una nuova revisione';
    end if;
end;
$$;

rollback;
