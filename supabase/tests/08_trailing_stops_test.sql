-- ============================================================================
-- Trailing-stop tests (spot + leverage). Prices pinned; tick functions called
-- directly. GOGL pinned at 100.00, spread 0.002 (bid 99.90, ask 100.10).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(11);

update public.assets set current_price = 100.00, fair_value = 100.00, flow = 0
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
-- Spot trailing stop.
-- ---------------------------------------------------------------------------
insert into r values ('buy', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 10));
select is(receipt ->> 'status', 'filled', 'spot position opened') from r where label = 'buy';

-- Trail 10% below the bid. bid 99.90 → stop 89.91.
insert into r values ('trail', set_trailing_stop(
  (select id from assets where symbol = 'GOGL'), 0.10, true));
select is(receipt ->> 'status', 'protected', 'trailing stop set') from r where label = 'trail';
select is(limit_price, 89.9100::numeric(18,4), 'initial stop is 10% below bid')
  from orders where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
   and status = 'pending' and order_type = 'stop';

-- Price rallies to 150: the stop ratchets up to bid(149.85) − 10% = 134.865.
update public.assets set current_price = 150.00 where symbol = 'GOGL';
select game.execute_triggered_orders();
select is(limit_price, 134.8650::numeric(18,4), 'stop ratcheted up with the price')
  from orders where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
   and status = 'pending' and order_type = 'stop';

-- Price eases to 140 (bid 139.86, above the 134.865 stop): stop does NOT drop.
update public.assets set current_price = 140.00 where symbol = 'GOGL';
select game.execute_triggered_orders();
select is(limit_price, 134.8650::numeric(18,4), 'stop never trails back down')
  from orders where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
   and status = 'pending' and order_type = 'stop';
select is(count(*)::int, 1, 'position still open above the stop')
  from holdings where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

-- Price drops through the ratcheted stop (bid 130.87 < 134.865): it fills.
update public.assets set current_price = 131.00 where symbol = 'GOGL';
select game.execute_triggered_orders();
select is(count(*)::int, 0, 'trailing stop closed the position')
  from holdings where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after the trailing-stop fill');

-- ---------------------------------------------------------------------------
-- Leveraged trailing stop (long).
-- ---------------------------------------------------------------------------
update public.assets set current_price = 100.00 where symbol = 'GOGL';
insert into public.user_asset_class_unlocks (user_id, class_id)
values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'margin')
on conflict do nothing;

insert into r values ('lev', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 5, 1000));
select is(receipt ->> 'status', 'opened', 'leveraged long opened') from r where label = 'lev';

-- Trail 5%. mark(bid) 99.90 → stop 94.905. Rally to 200 → stop ratchets up.
select set_leveraged_trailing_stop(
  (select id from leveraged_positions
    where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'open'),
  0.05, true);
update public.assets set current_price = 200.00 where symbol = 'GOGL';
select game.process_leveraged_positions();
select cmp_ok(stop_loss, '>', 150::numeric, 'leveraged trailing stop ratcheted up with the mark')
  from leveraged_positions
  where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'open';

-- Sharp drop below the ratcheted stop closes it via stop_loss (not liquidation).
update public.assets set current_price = 160.00 where symbol = 'GOGL';
select game.process_leveraged_positions();
select is(close_reason, 'stop_loss', 'leveraged position closed by the trailing stop')
  from leveraged_positions
  where user_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' and status = 'closed';

select * from finish();
rollback;
