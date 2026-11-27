with matches as (
    select id, registered_at
    from runloop_crm.accounts
    where ($1 = '' or strpos(lower(coalesce(email, '')), lower($1)) > 0
                   or strpos(lower(coalesce(display_name, '')), lower($1)) > 0
                   or strpos(id::text, lower($1)) > 0)
      and ($2 = 'all' or (email_confirmed_at is not null) = ($2 = 'confirmed'))
), page as (
    select id from matches order by registered_at desc nulls last, id
    limit $3 offset $4
)
select (select count(*)::int from matches) as total,
       coalesce(json_agg(d order by d.registered_at desc nulls last, d.id)
                filter (where d.id is not null), '[]') as users
from page join runloop_crm.directory d using (id);
