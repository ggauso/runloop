begin;

insert into auth.users (id) values
    ('f2020000-0000-0000-0000-000000000001'),
    ('f2020000-0000-0000-0000-000000000002');

do $$
begin
    if has_function_privilege('anon', 'public.runloop_consume_routing_quota(uuid)', 'EXECUTE')
        or has_function_privilege('authenticated', 'public.runloop_consume_routing_quota(uuid)', 'EXECUTE') then
        raise exception 'Il contatore è richiamabile da un ruolo client';
    end if;
end;
$$;

set local role service_role;

do $$
begin
    for request in 1..12 loop
        if not public.runloop_consume_routing_quota('f2020000-0000-0000-0000-000000000001') then
            raise exception 'Rifiutata la richiesta % prima del limite', request;
        end if;
    end loop;
    if public.runloop_consume_routing_quota('f2020000-0000-0000-0000-000000000001') then
        raise exception 'Valicato il limite di richieste';
    end if;
    if not public.runloop_consume_routing_quota('f2020000-0000-0000-0000-000000000002') then
        raise exception 'Il secondo utente ha ereditato il limite del primo';
    end if;
end;
$$;

reset role;
update runloop_private.routing_quota set window_start = statement_timestamp() - interval '1 minute'
    where user_id = 'f2020000-0000-0000-0000-000000000001';

do $$
begin
    if not public.runloop_consume_routing_quota('f2020000-0000-0000-0000-000000000001') then
        raise exception 'La prima richiesta della nuova finestra è stata rifiutata';
    end if;
    if (select requests from runloop_private.routing_quota
        where user_id = 'f2020000-0000-0000-0000-000000000001') <> 1 then
        raise exception 'Il contatore non si è azzerato nella nuova finestra';
    end if;
end;
$$;

rollback;
