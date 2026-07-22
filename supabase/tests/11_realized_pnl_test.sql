-- ============================================================================
-- Realized P/L on closing sells.
--
-- GOGL pinned at 100.00 (spread 0.002): ask 100.10, bid 99.90.
--   buy 10 @ 100.10  -> avg_cost 100.10
--   manual sell 4 @ 99.90 -> realized (99.90 - 100.10) * 4 = -0.80
--   SL @ 95 fires after price drops to 90 -> fill 89.91 on the last 6:
--     realized (89.91 - 100.10) * 6 = -61.14
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(7);

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

-- Open the position.
insert into r values ('buy', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 10));
select is(receipt ->> 'status', 'filled', 'position opened') from r where label = 'buy';

-- Buys carry no realized P/L.
select ok(realized_pnl is null, 'buy order has no realized P/L')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and side = 'buy';

-- Manual partial sell reports its realized P/L in the receipt and on the order.
insert into r values ('sell', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'sell', 4));
select is((receipt ->> 'realized_pnl')::numeric, -0.80::numeric,
  'manual sell receipt reports realized loss') from r where label = 'sell';
select is(realized_pnl, -0.80::numeric(18,2), 'sell order stamped with realized P/L')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and side = 'sell' and status = 'filled';
select is(close_avg_cost, 100.1000::numeric(18,4), 'sell order stamped with cost basis')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and side = 'sell' and status = 'filled';

-- Stop-loss fires server-side on the remaining 6 units.
insert into r values ('sl', set_position_protection(
  (select id from assets where symbol = 'GOGL'), null, 95));
update public.assets set current_price = 90 where symbol = 'GOGL';
select game.execute_triggered_orders();

select is(realized_pnl, -61.14::numeric(18,2),
  'stop-loss fill stamped with realized P/L')
  from orders where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
   and order_type = 'stop' and status = 'filled';

select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after realized-P/L fills');

select * from finish();
rollback;
