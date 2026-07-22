-- ============================================================================
-- Buy-side limit / stop ("future") order tests.
--
-- Prices are pinned and game.execute_triggered_orders() is called directly so
-- every fill is deterministic. GOGL pinned at 100.00, spread 0.002
-- (ask 100.10, bid 99.90).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(15);

update public.assets set current_price = 100.00, fair_value = 100.00, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'authenticated', 'authenticated', 'bob@example.test',
        '{"display_name": "Bob"}'::jsonb);

select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------
insert into r values ('limit_high', place_pending_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 5, 'limit', 120));
select is(receipt ->> 'reason', 'limit price must be below the current price',
  'limit buy above market rejected') from r where label = 'limit_high';

insert into r values ('stop_low', place_pending_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 5, 'stop', 90));
select is(receipt ->> 'reason', 'stop price must be above the current price',
  'stop buy below market rejected') from r where label = 'stop_low';

select throws_ok(
  $$select place_pending_order((select id from assets where symbol = 'GOGL'),
      'sell', 5, 'limit', 90)$$,
  'P0001', null, 'sell entry order raises (use protection instead)');

select throws_ok(
  $$select place_pending_order((select id from assets where symbol = 'GOGL'),
      'buy', 0, 'limit', 90)$$,
  'P0001', null, 'zero quantity raises');

-- ---------------------------------------------------------------------------
-- Happy path: a limit buy below market, then the price dips through it.
-- ---------------------------------------------------------------------------
insert into r values ('limit_ok', place_pending_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 10, 'limit', 90));
select is(receipt ->> 'status', 'placed', 'limit buy queued') from r where label = 'limit_ok';
select is(count(*)::int, 1, 'one pending buy order')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and status = 'pending' and side = 'buy';

-- Price above the limit: nothing fires.
select game.execute_triggered_orders();
select is(count(*)::int, 1, 'buy holds while price is above the limit')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and status = 'pending' and side = 'buy';
select is(count(*)::int, 0, 'no holding yet')
  from holdings where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

-- Price dips so ask (89.91) <= 90: the order fills at the live ask.
update public.assets set current_price = 89.83 where symbol = 'GOGL';
select game.execute_triggered_orders();

select is(count(*)::int, 1, 'limit buy executed')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and side = 'buy' and order_type = 'limit' and status = 'filled';
select is(quantity, 10::numeric, 'holding created at full quantity')
  from holdings where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and asset_id = (select id from assets where symbol = 'GOGL');
select is(side, 'buy', 'a buy trade was recorded')
  from trades where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select cmp_ok(cash_balance, '<', 10000::numeric, 'cash was spent on the fill')
  from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after the buy fill');

-- ---------------------------------------------------------------------------
-- Insufficient cash at fill: a queued buy is cancelled, never overdrawn.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 200.00, fair_value = 200.00 where symbol = 'GOGL';
insert into r values ('poor', place_pending_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 1, 'limit', 150));
select is(receipt ->> 'status', 'placed', 'second limit buy queued') from r where label = 'poor';

-- Force poverty directly (this deliberately desyncs the ledger, so we assert
-- the cancel behaviour here, not reconciliation).
update public.profiles set cash_balance = 5
 where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
update public.assets set current_price = 140.00 where symbol = 'GOGL';  -- ask 140.14 <= 150
select game.execute_triggered_orders();
select is(count(*)::int, 1, 'unaffordable queued buy cancelled, not filled')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and side = 'buy' and status = 'cancelled' and reject_reason = 'insufficient cash';

select * from finish();
rollback;
