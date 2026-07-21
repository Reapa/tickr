-- ============================================================================
-- Take-profit / stop-loss engine tests.
--
-- Prices are pinned and game.execute_triggered_orders() is called directly
-- (never the full tick) so every fill is deterministic.
--
-- Cash ledger walked through this file (GOGL pinned at 182.50, spread 0.002):
--   signup                        10000.00
--   buy 10 @ ask 182.6825         -1826.83   + first_trade 250  =>  8423.17
--   set stop loss (mission)        +500                         =>  8923.17
--   TP triggers: sell 10 @ 219.78 +2197.80   + take_profit 500  => 11620.97
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Serialize against the live pg_cron tick: hold the tick's advisory lock
-- for this whole transaction so in-test ticks always run and background
-- ticks no-op instead of blocking on our pinned rows.
select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(22);

update public.assets set current_price = 182.50, fair_value = 182.50, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'alice@example.test',
        '{"display_name": "Alice"}'::jsonb);

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

insert into r values ('buy', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 10));
select is(receipt ->> 'status', 'filled', 'position opened') from r where label = 'buy';

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------
insert into r values ('nopos', set_position_protection(
  (select id from assets where symbol = 'XOFF'), 200, null));
select is(receipt ->> 'reason', 'no open position', 'protection needs a position')
  from r where label = 'nopos';

insert into r values ('tp_low', set_position_protection(
  (select id from assets where symbol = 'GOGL'), 100, null));
select is(receipt ->> 'reason', 'take profit must be above the current price',
  'TP below price rejected') from r where label = 'tp_low';

insert into r values ('sl_high', set_position_protection(
  (select id from assets where symbol = 'GOGL'), null, 300));
select is(receipt ->> 'reason', 'stop loss must be below the current price',
  'SL above price rejected') from r where label = 'sl_high';

select throws_ok(
  $$select set_position_protection((select id from assets where symbol = 'GOGL'), null, null)$$,
  'P0001', null, 'setting neither TP nor SL raises');

-- ---------------------------------------------------------------------------
-- Happy path: TP 200 + SL 150 on 10 GOGL.
-- ---------------------------------------------------------------------------
insert into r values ('protect', set_position_protection(
  (select id from assets where symbol = 'GOGL'), 200, 150));
select is(receipt ->> 'status', 'protected', 'TP and SL set') from r where label = 'protect';
select is(count(*)::int, 2, 'one pending TP and one pending SL')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and status = 'pending';
select is(status, 'completed', 'set_stop_loss mission completed')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'set_stop_loss');
select is(cash_balance, 8923.17::numeric(18,2), 'mission reward paid: 8423.17 + 500')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- Replacement: new TP cancels the old one.
insert into r values ('replace', set_position_protection(
  (select id from assets where symbol = 'GOGL'), 210, null));
select is(count(*)::int, 1, 'replacing TP leaves exactly one pending TP')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and status = 'pending' and order_type = 'limit';
select is(count(*)::int, 1, 'old TP cancelled as replaced')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and status = 'cancelled' and reject_reason = 'replaced';

-- Cancel and re-set the SL (no double mission reward).
select lives_ok(
  $$select cancel_pending_order((select id from orders
      where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        and status = 'pending' and order_type = 'stop'))$$,
  'player can cancel a pending trigger');
select throws_ok(
  $$select cancel_pending_order('00000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'cancelling a non-pending order raises');
insert into r values ('resl', set_position_protection(
  (select id from assets where symbol = 'GOGL'), null, 150));
select is(cash_balance, 8923.17::numeric(18,2), 'no double mission reward')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- ---------------------------------------------------------------------------
-- No trigger while the price sits between SL and TP.
-- ---------------------------------------------------------------------------
select game.execute_triggered_orders();
select is(count(*)::int, 2, 'triggers hold while price is in range')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and status = 'pending';

-- ---------------------------------------------------------------------------
-- Price rallies through the TP: sell fills at the live bid (220 * 0.999),
-- position closes, the SL auto-cancels (one-cancels-other).
-- ---------------------------------------------------------------------------
update public.assets set current_price = 220 where symbol = 'GOGL';
select game.execute_triggered_orders();

-- (created_at is transaction-time here, so filter by state, never by order)
select is(count(*)::int, 1, 'take profit executed')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and order_type = 'limit' and status = 'filled';
select is(price, 219.7800::numeric(18,4), 'filled at live bid, not the trigger price')
  from trades where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and side = 'sell';
select is(count(*)::int, 0, 'position fully closed')
  from holdings where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(count(*)::int, 1, 'orphaned stop loss auto-cancelled (one-cancels-other)')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and order_type = 'stop' and reject_reason = 'position closed';
select is(cash_balance, 11620.97::numeric(18,2),
  'proceeds + take_profit mission: 8923.17 + 2197.80 + 500')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(status, 'completed', 'take_profit mission completed by the trigger fill')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'take_profit');
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after triggered fills');

select * from finish();
rollback;
