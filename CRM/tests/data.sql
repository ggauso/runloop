-- Run inside the transaction prepared by check-db.sh. All fixtures roll back.
create temporary table crm_before as execute crm_overview(7);
insert into auth.users (id, email, created_at, email_confirmed_at, is_anonymous, deleted_at) values
('15cbc091-cd62-405b-a005-000000000001','crm%fixture1@example.invalid',now(),now(),false,null),
('15cbc091-cd62-405b-a005-000000000002','crm%fixture2@example.invalid',now() - interval '10 days',null,false,null),
('15cbc091-cd62-405b-a005-000000000003','crm%fixture3@example.invalid',now(),null,true,null),
('15cbc091-cd62-405b-a005-000000000004','crm%fixture4@example.invalid',now(),null,false,now());
insert into public.profiles (id,display_name) values ('15cbc091-cd62-405b-a005-000000000001','Nome CRM di prova');
insert into public.routes (id,owner_id,name,mode,distance_m,geometry,provider)
values ('15cbc091-cd62-405b-a005-000000000010','15cbc091-cd62-405b-a005-000000000001','CRM test','manual',100,
        extensions.st_geomfromtext('LINESTRING(8 45,8.01 45.01)',4326),'fixture');
insert into public.workouts (id,owner_id,started_at,ended_at,active_duration_s,distance_m,upload_complete) values
('15cbc091-cd62-405b-a005-000000000011','15cbc091-cd62-405b-a005-000000000001',now(),now(),0,0,true),
('15cbc091-cd62-405b-a005-000000000012','15cbc091-cd62-405b-a005-000000000001',now()-interval '10 days',now(),0,0,true),
('15cbc091-cd62-405b-a005-000000000013','15cbc091-cd62-405b-a005-000000000002',now(),now(),0,0,false),
('15cbc091-cd62-405b-a005-000000000014','15cbc091-cd62-405b-a005-000000000003',now(),now(),0,0,true),
('15cbc091-cd62-405b-a005-000000000015','15cbc091-cd62-405b-a005-000000000004',now(),now(),0,0,true);
grant select on crm_before to runloop_crm_reader;
set local role runloop_crm_reader;
create temporary table crm_after as execute crm_overview(7);
create temporary table crm_page as execute crm_users('crm%fixture','all',1,0);
create temporary table crm_pending as execute crm_users('crm%fixture','pending',20,0);
do $$
declare baseline record; result record;
begin
    select * into strict baseline from crm_before;
    select * into strict result from crm_after;
    if row(result.registered, result.new_users, result.confirmed, result.active, result.workouts, result.routes)
       is distinct from row(baseline.registered+2, baseline.new_users+1, baseline.confirmed+1, baseline.active+1,
                            baseline.workouts+1, baseline.routes+1) then
        raise exception 'Totali errati con account senza profilo, attività multiple o upload parziale';
    end if;
    if json_array_length(result.daily) <> 7
       or result.daily->0->>'day' <> (current_date-6)::text
       or result.daily->6->>'day' <> current_date::text
       or (result.daily->6->>'workouts')::int <> (baseline.daily->6->>'workouts')::int+1 then
        raise exception 'Intervallo giornaliero errato';
    end if;
    select * into strict result from crm_page;
    if result.total <> 2 or json_array_length(result.users) <> 1
       or result.users->0->>'display_name' <> 'Nome CRM di prova'
       or (result.users->0->>'workouts')::int <> 2 or (result.users->0->>'routes')::int <> 1 then
        raise exception 'Ricerca, paginazione o storico account errati';
    end if;
    select * into strict result from crm_pending;
    if result.total <> 1 or (result.users->0->>'workouts')::int <> 0
       or result.users->0->>'last_activity_at' is not null then
        raise exception 'Filtro conferma o gestione account senza attività errati';
    end if;
end;
$$;
reset role;
do $$
begin
    if has_table_privilege('runloop_crm_reader','auth.users','select')
       or has_table_privilege('runloop_crm_reader','public.workouts','select')
       or has_table_privilege('runloop_crm_reader','public.workout_points','select')
       or has_table_privilege('runloop_crm_reader','runloop_crm.accounts','update')
       or has_schema_privilege('authenticated','runloop_crm','usage')
       or has_schema_privilege('anon','runloop_crm','usage') then
        raise exception 'Permessi CRM troppo ampi';
    end if;
end;
$$;
rollback;
