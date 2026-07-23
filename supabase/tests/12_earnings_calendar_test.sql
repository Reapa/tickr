-- ============================================================================
-- Earnings calendar: scheduling, hidden outcome, and resolution into news.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(9);

-- ---------------------------------------------------------------------------
-- Resolution: a due earnings emits a real market_event with the hidden outcome
-- revealed, and marks itself resolved; a not-yet-due one is left alone.
-- ---------------------------------------------------------------------------
insert into public.scheduled_events
  (asset_id, kind, headline, quarter, scheduled_at, resolves_at,
   sentiment, fv_impact, vol_multiplier)
values
  ((select id from public.assets where symbol = 'GOGL'), 'earnings',
   'Googol reports Q3 earnings', 'Q3',
   now() - interval '2 minutes', now() - interval '1 second',
   'positive', 0.0500, 1.5),
  ((select id from public.assets where symbol = 'ENVD'), 'earnings',
   'Envidia reports Q3 earnings', 'Q3',
   now(), now() + interval '1 hour',
   'negative', -0.0800, 1.6);

select game.resolve_scheduled_events();

select is(status, 'resolved', 'due earnings marked resolved')
  from public.scheduled_events
 where asset_id = (select id from public.assets where symbol = 'GOGL');
select isnt(resolved_event_id, null, 'resolved earnings links its market_event')
  from public.scheduled_events
 where asset_id = (select id from public.assets where symbol = 'GOGL');
select is(sentiment, 'positive', 'resolution reveals the hidden sentiment as news')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'GOGL')
   and headline like 'Googol%estimates';
select is(fv_impact, 0.0500::numeric(8,4), 'the hidden fv_impact carries into the news event')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'GOGL')
   and headline like 'Googol%estimates';
select is(status, 'scheduled', 'a future earnings is not resolved early')
  from public.scheduled_events
 where asset_id = (select id from public.assets where symbol = 'ENVD');

-- ---------------------------------------------------------------------------
-- Secrecy: the outcome columns are NOT granted to clients; the teaser is.
-- ---------------------------------------------------------------------------
select ok(not has_column_privilege('authenticated', 'public.scheduled_events', 'fv_impact', 'select'),
  'clients cannot read the hidden fv_impact outcome');
select ok(has_column_privilege('authenticated', 'public.scheduled_events', 'headline', 'select'),
  'clients can read the public teaser headline');

-- ---------------------------------------------------------------------------
-- Scheduling + the concurrency cap.
-- ---------------------------------------------------------------------------
truncate public.scheduled_events;
update public.game_config set value = '2' where key = 'earnings_max_pending';
-- Pin to earnings (scheduling can otherwise roll a rumour, migration 36).
update public.game_config set value = '0' where key = 'rumour_share';

select game.schedule_earnings_event();
select ok((select count(*) from public.scheduled_events
            where status = 'scheduled' and kind = 'earnings'
              and resolves_at > now()) >= 1,
  'scheduling creates an upcoming earnings announcement');

do $$ begin
  for i in 1..6 loop perform game.schedule_earnings_event(); end loop;
end $$;
select ok((select count(*) from public.scheduled_events where status = 'scheduled') <= 2,
  'the concurrency cap bounds pending earnings');

select * from finish();
rollback;
