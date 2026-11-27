-- The connection uses Europe/Rome, including calendar days around DST changes.
with days as (
    select current_date - n as day from generate_series(0, $1::int - 1) n
), signups as (
    select registered_at + interval '168 hours' as deadline,
           exists (
               select 1 from runloop_crm.activity activity
               where activity.owner_id = account.id and activity.kind = 'workout'
                 and activity.synced_at between account.registered_at
                                          and least(account.registered_at + interval '168 hours', now())
           ) as synced_in_week
    from runloop_crm.accounts account
    where registered_at between (select min(day) from days) and now()
), events as (
    select owner_id, kind, occurred_at::date as day
    from runloop_crm.activity
    where occurred_at >= (select min(day) from days) and occurred_at <= now()
), daily as (
    select d.day::text,
           count(e.kind) filter (where e.kind = 'route')::int as routes,
           count(e.kind) filter (where e.kind = 'workout')::int as workouts
    from days d left join events e on e.day = d.day group by d.day
)
select now() as as_of,
       count(*)::int as registered,
       count(email_confirmed_at)::int as confirmed,
       (select count(*)::int from signups) as new_users,
       (select count(*)::int from signups where synced_in_week) as first_sync_in_week,
       (select count(*)::int from signups where not synced_in_week and deadline > now()) as first_sync_pending,
       (select count(distinct owner_id)::int from events) as active,
       (select count(*)::int from events where kind = 'route') as routes,
       (select count(*)::int from events where kind = 'workout') as workouts,
       (select json_agg(daily order by day) from daily) as daily,
       coalesce((select json_agg(recent order by registered_at desc nulls last, id)
                 from (select * from runloop_crm.directory order by registered_at desc nulls last, id limit 5) recent),
                '[]') as recent_users
from runloop_crm.accounts;
