-- Runs on the isolated database after the other fixtures have rolled back.
do $$
begin
    if not exists (
        select from public.workouts w join auth.users u on u.id = w.owner_id
        where w.id = '81fa2253-0000-4000-8000-000000000011'
          and w.first_synced_at = u.created_at + interval '168 hours'
          and w.updated_at = w.first_synced_at
    ) then raise exception 'La migrazione deve conservare i tempi degli invii storici'; end if;
end;
$$;

create temporary table crm_empty_week as execute crm_overview(7);
do $$
begin
    if not exists (select from crm_empty_week where new_users = 0 and first_sync_in_week = 0 and first_sync_pending = 0)
    then raise exception 'Nessun iscritto deve dare conteggi pari a zero nel periodo'; end if;
end;
$$;

-- The old workout is retransmitted after the deadline. Its first sync stays fixed.
update public.workouts set upload_complete = true where id = '81fa2253-0000-4000-8000-000000000011';
insert into auth.users (id, created_at) values
('81fa2253-0000-4000-8000-000000000002', now() - interval '2 days'),
('81fa2253-0000-4000-8000-000000000003', now() - interval '1 day'),
('81fa2253-0000-4000-8000-000000000004', now() - interval '8 days'),
('81fa2253-0000-4000-8000-000000000005', now() - interval '40 days');
-- A backlog, a second workout, a partial upload and a late completion.
insert into public.workouts (id, owner_id, started_at, ended_at, active_duration_s, distance_m, upload_complete)
values
('81fa2253-0000-4000-8000-000000000012','81fa2253-0000-4000-8000-000000000002',now()-interval '20 days',now()-interval '20 days',0,0,false),
('81fa2253-0000-4000-8000-000000000013','81fa2253-0000-4000-8000-000000000002',now(),now(),0,0,true),
('81fa2253-0000-4000-8000-000000000014','81fa2253-0000-4000-8000-000000000003',now(),now(),0,0,false),
('81fa2253-0000-4000-8000-000000000015','81fa2253-0000-4000-8000-000000000004',now()-interval '2 days',now(),0,0,true);
update public.workouts set upload_complete = true where id = '81fa2253-0000-4000-8000-000000000012';
-- Move one account's registration to exactly one microsecond outside the boundary.
update auth.users u set created_at = w.first_synced_at - interval '168 hours' - interval '1 microsecond'
from public.workouts w where w.owner_id = u.id and w.id = '81fa2253-0000-4000-8000-000000000015';

do $$
begin
    if not exists (select from public.workouts where id = '81fa2253-0000-4000-8000-000000000012' and first_synced_at > started_at)
       or not exists (select from public.workouts where id = '81fa2253-0000-4000-8000-000000000014' and first_synced_at is null)
    then raise exception 'Il primo invio deve ricevere una data solo al completamento'; end if;
end;
$$;

set role runloop_crm_reader;
create temporary table crm_week as execute crm_overview(7);
create temporary table crm_month as execute crm_overview(30);
create temporary table crm_quarter as execute crm_overview(90);
do $$
begin
    if not exists (select from crm_week where new_users = 2 and first_sync_in_week = 1 and first_sync_pending = 1)
       or not exists (select from crm_month where new_users = 4 and first_sync_in_week = 2 and first_sync_pending = 1)
       or not exists (select from crm_quarter where new_users = 5 and first_sync_in_week = 2 and first_sync_pending = 1)
    then raise exception 'Conteggi della prima sincronizzazione errati per coorte o finestra di osservazione'; end if;
end;
$$;
