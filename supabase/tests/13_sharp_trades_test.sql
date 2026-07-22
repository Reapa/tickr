-- ============================================================================
-- "Sharp Trade" variable-ratio XP bonus.
--
-- All orders in a test transaction share created_at (transaction time), so we
-- identify each order by the order_id returned in its receipt.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(9);

update public.assets set current_price = 100, fair_value = 100, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        'authenticated', 'authenticated', 'carol@example.test',
        '{"display_name": "Carol"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

-- ---------------------------------------------------------------------------
-- The roll in isolation.
-- ---------------------------------------------------------------------------
select is(game.roll_sharp_trade(1000, -5), 1, 'a loss never rolls a bonus');
select is(game.roll_sharp_trade(10, 100), 1, 'below min notional never rolls a bonus');
update public.game_config set value = '1' where key = 'sharp_trade_chance';
select ok(game.roll_sharp_trade(1000, 100) between 2 and 10,
  'a forced roll yields a 2-10x multiplier');

-- ---------------------------------------------------------------------------
-- chance = 0: a profitable sell earns the flat rate; buys carry no multiplier.
-- ---------------------------------------------------------------------------
update public.game_config set value = '0' where key = 'sharp_trade_chance';
insert into r values ('b1', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'buy', 10));
select ok((select xp_multiplier is null from public.orders
             where id = (select (receipt ->> 'order_id')::uuid from r where label = 'b1')),
  'a buy carries no xp multiplier');

update public.assets set current_price = 200 where symbol = 'GOGL';
insert into r values ('s0', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'sell', 10));
select is((select xp_multiplier from public.orders
             where id = (select (receipt ->> 'order_id')::uuid from r where label = 's0')),
  1, 'no bonus when the chance is 0');

-- ---------------------------------------------------------------------------
-- chance = 1: a profitable sell rolls a 2-10x Sharp Trade, in receipt + order.
-- ---------------------------------------------------------------------------
update public.game_config set value = '1' where key = 'sharp_trade_chance';
insert into r values ('b2', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'buy', 10));
update public.assets set current_price = 400 where symbol = 'GOGL';
insert into r values ('s1', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'sell', 10));
select ok((receipt ->> 'xp_multiplier')::int between 2 and 10,
  'profitable sell rolls a 2-10x Sharp Trade (receipt)') from r where label = 's1';
select ok((select xp_multiplier from public.orders
             where id = (select (receipt ->> 'order_id')::uuid from r where label = 's1'))
           between 2 and 10,
  'Sharp Trade multiplier stamped on the order');

-- ---------------------------------------------------------------------------
-- chance = 1 but a losing close: still no bonus.
-- ---------------------------------------------------------------------------
insert into r values ('b3', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'buy', 10));
update public.assets set current_price = 200 where symbol = 'GOGL';
insert into r values ('s2', place_market_order(
  (select id from public.assets where symbol = 'GOGL'), 'sell', 10));
select is((select xp_multiplier from public.orders
             where id = (select (receipt ->> 'order_id')::uuid from r where label = 's2')),
  1, 'a losing close rolls no bonus even at 100% chance');

select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after Sharp Trade fills');

select * from finish();
rollback;
