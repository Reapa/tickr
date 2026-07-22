-- ============================================================================
-- Dynamic (daily / weekly) missions. GOGL pinned at 100.00 so market buys are
-- deterministic. Markets forced open so trades fill regardless of hours.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(6);

update public.assets set current_price = 100.00, fair_value = 100.00, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        'authenticated', 'authenticated', 'dave@example.test',
        '{"display_name": "Dave"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "role": "authenticated"}', true);

-- --------------------------------------------------------------------------
-- Lazy assignment: refreshing the board draws a daily + weekly subset.
-- --------------------------------------------------------------------------
select refresh_my_missions();
select is(
  (select count(*)::int from user_missions
    where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' and cadence = 'daily'),
  3, 'refresh assigns a 3-mission daily board');
select is(
  (select count(*)::int from user_missions
    where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' and cadence = 'weekly'),
  2, 'refresh assigns a 2-mission weekly board');

-- Period key is the UTC calendar day.
select is(game.period_key('daily', '2026-07-22T05:00:00Z'::timestamptz),
          '2026-07-22', 'daily period key is the UTC date');

-- --------------------------------------------------------------------------
-- Deterministic daily completion: pin the board to "place 3 trades", trade 3x.
-- --------------------------------------------------------------------------
delete from user_missions
 where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' and cadence = 'daily';
insert into user_missions (user_id, mission_id, cadence, period_key, assigned_at, expires_at)
select 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', id, 'daily',
       game.period_key('daily'), now(), game.period_end('daily')
  from missions where code = 'daily_trade_3';

select place_market_order((select id from assets where symbol = 'GOGL'), 'buy', 1);
select place_market_order((select id from assets where symbol = 'GOGL'), 'buy', 1);
select place_market_order((select id from assets where symbol = 'GOGL'), 'buy', 1);

select is(
  (select status from user_missions
    where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
      and mission_id = (select id from missions where code = 'daily_trade_3')),
  'completed', 'daily_trade_3 completes after 3 trades this cycle');
select is(
  (select count(*)::int from transactions
    where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
      and type = 'mission_reward' and ref_id = 'daily_trade_3' and cash_delta = 750),
  1, 'daily_trade_3 pays its cash reward once');

-- --------------------------------------------------------------------------
-- Weekly completion additionally grants premium gems. Lower the bar so the
-- three trades above satisfy it, then evaluate.
-- --------------------------------------------------------------------------
update missions set criteria = '{"count":1}' where code = 'weekly_trade_20';
delete from user_missions
 where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' and cadence = 'weekly';
insert into user_missions (user_id, mission_id, cadence, period_key, assigned_at, expires_at)
select 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', id, 'weekly',
       game.period_key('weekly'), now(), game.period_end('weekly')
  from missions where code = 'weekly_trade_20';
select game.evaluate_missions('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
select is(
  (select count(*)::int from premium_ledger
    where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
      and reason = 'weekly_mission_bonus' and delta = 15),
  1, 'completing a weekly grants premium gems');

select * from finish();
rollback;
