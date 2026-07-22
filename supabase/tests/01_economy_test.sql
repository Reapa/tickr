-- ============================================================================
-- Economy tests: order execution, ledger reconciliation, unlock gating,
-- net-worth calculation. Run with `supabase test db` (pgTAP).
-- Assumes a freshly seeded database (supabase db reset).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Serialize against the live pg_cron tick: hold the tick's advisory lock
-- for this whole transaction so in-test ticks always run and background
-- ticks no-op instead of blocking on our pinned rows.
select pg_advisory_xact_lock(hashtext('game.market_tick'));

-- Trading-hours override: these suites must pass at any wall-clock time.
update public.game_config set value = 'true' where key = 'markets_always_open';

select plan(37);

-- ---------------------------------------------------------------------------
-- Fixture: the market is LIVE (pg_cron ticks every 5s), so pin the assets
-- under test back to known prices inside this transaction. The row locks
-- this takes also hold concurrent ticks off until we roll back, keeping
-- every fill below deterministic.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 182.50, fair_value = 182.50, flow = 0
 where symbol = 'GOGL';
update public.assets set current_price = 1250.00, fair_value = 1250.00, flow = 0
 where symbol = 'DWTN';

-- ---------------------------------------------------------------------------
-- Fixture: sign up Alice through the real auth trigger.
-- ---------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'alice@example.test',
        '{"display_name": "Alice"}'::jsonb);

select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

-- Onboarding
select is(cash_balance, 10000.00::numeric(18,2), 'starting cash granted through the ledger')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(premium_balance, 200, 'welcome premium granted')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select ok(game.has_class_unlock('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'stocks'),
  'stocks unlocked at signup');
select ok(not game.has_class_unlock('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'real_estate'),
  'real estate locked at signup');
-- Onboarding enrolls the permanent milestones only; the rotating daily/weekly
-- board is assigned lazily on first Missions-screen load (refresh_my_missions).
select is(
  (select count(*) from user_missions
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select count(*) from missions where is_active and cadence = 'permanent'),
  'permanent missions enrolled at signup');
select is(starting_net_worth, 10000.00::numeric(18,2), 'joined active season at starting cash')
  from season_scores where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- ---------------------------------------------------------------------------
-- Market buy: GOGL @ 182.50, spread 0.002 -> ask 182.6825, 10 shares.
-- notional 1826.83; first_trade mission pays 250 => cash 8423.17.
-- ---------------------------------------------------------------------------
create temp table r (label text primary key, receipt jsonb);

insert into r values ('buy1', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 10));

select is(receipt ->> 'status', 'filled', 'buy order fills') from r where label = 'buy1';
select is((receipt ->> 'price')::numeric, 182.6825,
  'buyer pays current price plus half spread') from r where label = 'buy1';
select is(cash_balance, 8423.17::numeric(18,2),
  'cash = 10000 - 1826.83 notional + 250 first-trade reward')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(quantity, 10.0000::numeric(18,4), 'holding created with bought quantity')
  from holdings where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and asset_id = (select id from assets where symbol = 'GOGL');
-- Cost basis derives from actual cash moved (notional rounded to cents:
-- 1826.83 / 10), not the quoted price — so it always reconciles to the ledger.
select is(avg_cost, 182.6830::numeric(18,4), 'avg cost = cash spent / units bought')
  from holdings where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and asset_id = (select id from assets where symbol = 'GOGL');
select is(xp, 60, 'xp = 10 per trade + 50 mission reward')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(status, 'completed', 'first_trade mission completed')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'first_trade');
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after buy');

-- ---------------------------------------------------------------------------
-- Market sell: 4 shares at bid 182.3175 -> +729.27 => cash 9152.44.
-- ---------------------------------------------------------------------------
insert into r values ('sell1', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'sell', 4));

select is((receipt ->> 'price')::numeric, 182.3175,
  'seller receives current price minus half spread') from r where label = 'sell1';
select is(cash_balance, 9152.44::numeric(18,2), 'sell proceeds credited')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(quantity, 6.0000::numeric(18,4), 'holding reduced')
  from holdings where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and asset_id = (select id from assets where symbol = 'GOGL');
select is(avg_cost, 182.6830::numeric(18,4), 'avg cost unchanged by sells')
  from holdings where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and asset_id = (select id from assets where symbol = 'GOGL');

-- ---------------------------------------------------------------------------
-- Rejections are persisted, never destructive.
-- ---------------------------------------------------------------------------
insert into r values ('oversell', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'sell', 10));
select is(receipt ->> 'reason', 'insufficient holdings', 'cannot sell more than held')
  from r where label = 'oversell';
select is(count(*)::int, 1, 'rejected order persisted for audit')
  from orders where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and status = 'rejected';

insert into r values ('bigbuy', place_market_order(
  (select id from assets where symbol = 'GOGL'), 'buy', 1000));
select is(receipt ->> 'reason', 'insufficient cash', 'cannot buy beyond cash')
  from r where label = 'bigbuy';

insert into r values ('locked', place_market_order(
  (select id from assets where symbol = 'DWTN'), 'buy', 1));
select is(receipt ->> 'reason', 'asset class locked',
  'locked asset classes are not tradeable') from r where label = 'locked';

-- ---------------------------------------------------------------------------
-- Progression: unlock real estate.
-- ---------------------------------------------------------------------------
insert into r values ('unlock_poor', purchase_asset_class_unlock('real_estate'));
select is(receipt ->> 'reason', 'insufficient cash', 'unlock gated by cash')
  from r where label = 'unlock_poor';

-- Server-side grant (test fixture money flows through the ledger too).
insert into transactions (user_id, type, cash_delta, ref_type, ref_id)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 100000, 'mission', 'test-grant');

insert into r values ('unlock_ok', purchase_asset_class_unlock('real_estate'));
select is(receipt ->> 'status', 'unlocked', 'unlock succeeds with funds')
  from r where label = 'unlock_ok';
select is(cash_balance, 59152.44::numeric(18,2), 'unlock cost debited: 109152.44 - 50000')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select ok(game.has_class_unlock('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'real_estate'),
  'unlock recorded');

insert into r values ('re_buy', place_market_order(
  (select id from assets where symbol = 'DWTN'), 'buy', 10));
select is(receipt ->> 'status', 'filled', 'unlocked class becomes tradeable')
  from r where label = 're_buy';
select is(cash_balance, 46621.19::numeric(18,2), 'DWTN notional 12531.25 debited')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- Missions that should NOT have completed (sell was below avg cost; only 2 sectors).
select is(status, 'active', 'take_profit not completed by a losing sell')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'take_profit');
select is(status, 'active', 'diversify_3 needs three sectors')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'diversify_3');

-- ---------------------------------------------------------------------------
-- The tick: prices move, ticks recorded, net worth = cash + marked holdings.
-- ---------------------------------------------------------------------------
select lives_ok('select game.market_tick()', 'tick runs');
select ok((select count(*) from price_ticks) >= (select count(*) from assets where is_active),
  'tick recorded a price for every active asset');
select is(
  (select net_worth from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select (p.cash_balance + coalesce((
      select sum(h.quantity * a.current_price)
        from holdings h join assets a on a.id = h.asset_id
       where h.user_id = p.id), 0))::numeric(18,2)
     from profiles p where p.id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'net worth = cash + mark-to-market holdings');
select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger still reconciles after tick');

-- ---------------------------------------------------------------------------
-- Ledger hardening.
-- ---------------------------------------------------------------------------
select throws_ok(
  'update transactions set cash_delta = 999 where true',
  'P0001', null, 'ledger rows cannot be updated');
select throws_ok(
  'delete from transactions where true',
  'P0001', null, 'ledger rows cannot be deleted');
select throws_ok(
  $$insert into transactions (user_id, type, cash_delta, ref_type)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'class_unlock', -99999999, 'class')$$,
  '23514', null, 'overdrafts blocked by CHECK even on direct ledger writes');

select * from finish();
rollback;
