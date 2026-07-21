-- ============================================================================
-- Monetization-safety + RLS tests.
--
-- Proves at the database level that premium currency is cosmetic-only, both
-- ledgers are append-only and constraint-guarded, simulation internals are
-- invisible to clients, and players can only read their own private rows.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select plan(27);

-- Fixtures: Alice and Bob via the real signup trigger.
insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000000', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'authenticated', 'authenticated', 'alice@example.test', '{"display_name": "Alice"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   'authenticated', 'authenticated', 'bob@example.test', '{"display_name": "Bob"}'::jsonb);

-- ---------------------------------------------------------------------------
-- The cosmetic-only guarantee: the CHECK sets are closed. There is no
-- transaction type that credits cash from premium, and no premium reason
-- that cashes out. These inserts run as postgres — even a compromised
-- server-side caller cannot cross the two economies.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$insert into transactions (user_id, type, cash_delta)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'premium_conversion', 5000)$$,
  '23514', null, 'no cash-ledger type exists for premium conversion');

select throws_ok(
  $$insert into premium_ledger (user_id, delta, reason)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', -100, 'cash_out')$$,
  '23514', null, 'no premium reason exists for cashing out');

select throws_ok(
  $$insert into premium_ledger (user_id, delta, reason, cosmetic_id)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 100, 'cosmetic_purchase',
            (select id from cosmetics where code = 'frame_bronze'))$$,
  '23514', null, 'cosmetic purchases must debit, not credit');

select throws_ok(
  $$insert into premium_ledger (user_id, delta, reason)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', -50, 'cosmetic_purchase')$$,
  '23514', null, 'premium spends must reference the cosmetic bought');

select throws_ok(
  $$insert into premium_ledger (user_id, delta, reason, cosmetic_id)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', -99999, 'cosmetic_purchase',
            (select id from cosmetics where code = 'frame_bronze'))$$,
  '23514', null, 'premium balance cannot go negative');

select throws_ok(
  'update premium_ledger set delta = 9999 where true',
  'P0001', null, 'premium ledger is append-only');

-- ---------------------------------------------------------------------------
-- Store flow (as Bob, welcome balance 200).
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);

create temp table r (label text primary key, receipt jsonb);

insert into r values ('bronze', purchase_cosmetic('frame_bronze'));
select is(receipt ->> 'status', 'purchased', 'cosmetic purchase succeeds') from r where label = 'bronze';
select is(premium_balance, 100, 'gems debited: 200 - 100')
  from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select is(count(*)::int, 1, 'ownership recorded')
  from user_cosmetics uc join cosmetics c on c.id = uc.cosmetic_id
 where uc.user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and c.code = 'frame_bronze';

insert into r values ('again', purchase_cosmetic('frame_bronze'));
select is(receipt ->> 'reason', 'already owned', 'no double purchase') from r where label = 'again';

insert into r values ('diamond_poor', purchase_cosmetic('frame_diamond'));
select is(receipt ->> 'reason', 'insufficient gems', 'store gated by balance')
  from r where label = 'diamond_poor';

insert into r values ('iap', stub_purchase_premium('large'));
select is(premium_balance, 1300, 'stub IAP grants premium: 100 + 1200')
  from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

insert into r values ('diamond_ok', purchase_cosmetic('frame_diamond'));
select is(receipt ->> 'status', 'purchased', 'purchase succeeds after top-up')
  from r where label = 'diamond_ok';

insert into r values ('season_locked', purchase_cosmetic('frame_season_1'));
select is(receipt ->> 'reason', 'not purchasable', 'season rewards cannot be bought')
  from r where label = 'season_locked';

-- Equip rules.
select lives_ok($$select equip_cosmetic('avatar_frame', 'frame_bronze')$$, 'equip owned cosmetic');
select is(equipped ->> 'avatar_frame', 'frame_bronze', 'loadout updated')
  from profiles where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select throws_ok($$select equip_cosmetic('profile_badge', 'badge_whale')$$,
  'P0001', null, 'cannot equip unowned cosmetics');
select throws_ok($$select equip_cosmetic('profile_badge', 'frame_bronze')$$,
  'P0001', null, 'cosmetics only fit their slot');

-- ---------------------------------------------------------------------------
-- RLS / column privileges as a real client role.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);

select throws_ok('select fair_value from assets limit 1',
  '42501', null, 'hidden fair value is invisible to clients');
select throws_ok('select flow from assets limit 1',
  '42501', null, 'order-flow accumulator is invisible to clients');
select lives_ok('select symbol, current_price from assets limit 1',
  'public price data is readable');
select throws_ok('select fv_impact from market_events limit 1',
  '42501', null, 'event answer key is invisible to clients');
select throws_ok(
  $$insert into transactions (user_id, type, cash_delta)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 1000000)$$,
  '42501', null, 'clients cannot write the ledger');
select throws_ok('update assets set current_price = 1 where true',
  '42501', null, 'clients cannot set prices');
select is(
  (select count(*) from transactions),
  (select count(*) from transactions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'players see only their own ledger rows');

set local role anon;
select lives_ok('select count(*) from price_ticks', 'anon can read public market data');
select throws_ok('select count(*) from profiles',
  '42501', null, 'anon cannot read player profiles');

reset role;
select * from finish();
rollback;
