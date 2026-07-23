-- ============================================================================
-- Rumours: variable confirmation — a confirmed rumour emits a real event, an
-- unconfirmed one fizzles into a neutral "unfounded" note.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';
update public.game_config set value = '0' where key = 'prediction_post_probability';

select plan(5);

-- A rumour forced to confirm (confirm_chance 1).
insert into public.scheduled_events
  (asset_id, kind, headline, scheduled_at, resolves_at, sentiment,
   fv_impact, vol_multiplier, confirm_chance)
values
  ((select id from public.assets where symbol = 'GOGL'), 'rumour',
   'Whispers of a takeover bid for Googol',
   now() - interval '2 minutes', now() - interval '1 second',
   'positive', 0.0500, 1.5, 1.0);

-- A rumour forced to fizzle (confirm_chance 0).
insert into public.scheduled_events
  (asset_id, kind, headline, scheduled_at, resolves_at, sentiment,
   fv_impact, vol_multiplier, confirm_chance)
values
  ((select id from public.assets where symbol = 'ENVD'), 'rumour',
   'Rumours swirl of an accounting probe at Envidia',
   now() - interval '2 minutes', now() - interval '1 second',
   'negative', -0.0800, 1.6, 0.0);

select game.resolve_scheduled_events();

select is(status, 'resolved', 'a confirmed rumour resolves')
  from public.scheduled_events
 where asset_id = (select id from public.assets where symbol = 'GOGL');
select is(sentiment, 'positive', 'a confirmed rumour emits its directional event')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'GOGL')
   and headline like 'Confirmed:%';
select is(fv_impact, 0.0500::numeric(8,4), 'the confirmed rumour carries its hidden impact')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'GOGL')
   and headline like 'Confirmed:%';

select is(sentiment, 'neutral', 'an unfounded rumour fizzles to a neutral note')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'ENVD')
   and headline like 'Unfounded:%';
select is(fv_impact, 0::numeric(8,4), 'an unfounded rumour moves the price by nothing')
  from public.market_events
 where asset_id = (select id from public.assets where symbol = 'ENVD')
   and headline like 'Unfounded:%';

select * from finish();
rollback;
