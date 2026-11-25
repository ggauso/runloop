begin;

create function runloop_private.track_route_geometry_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
    new.revision := old.revision;
    if not extensions.st_orderingequals(old.geometry, new.geometry) then
        new.revision := old.revision + 1;
    end if;
    return new;
end;
$$;

revoke all on function runloop_private.track_route_geometry_revision() from public, anon, authenticated;

create trigger routes_track_geometry_revision before update on public.routes
    for each row execute function runloop_private.track_route_geometry_revision();

commit;
