-- ============================================================================
-- Leverage engine tests. Prices pinned; game.process_leveraged_positions()
-- called directly so every liquidation/trigger is deterministic.
-- GOGL pinned at 182.50 (spread 0.002): long entry 182.6825, short 182.3175.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Serialize against the live pg_cron tick: hold the tick's advisory lock
-- for this whole transaction so in-test ticks always run and background
-- ticks no-op instead of blocking on our pinned rows.
select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(27);

update public.assets set current_price = 182.50, fair_value = 182.50, flow = 0
 where symbol = 'GOGL';

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000000', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'authenticated', 'authenticated', 'alice@example.test', '{"display_name": "Alice"}'::jsonb),
  ('00000000-0000-0000-0000-000000000000', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   'authenticated', 'authenticated', 'bob@example.test', '{"display_name": "Bob"}'::jsonb);

create temp table r (label text primary key, receipt jsonb);

-- Bob has no broker license.
select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);
insert into r values ('nolic', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 1000));
select is(receipt ->> 'reason', 'broker license required', 'leverage gated by unlock')
  from r where label = 'nolic';

-- Alice buys the license.
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);
insert into transactions (user_id, type, cash_delta, ref_type, ref_id)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 100000, 'mission', 'test-grant');
insert into r values ('lic', purchase_asset_class_unlock('margin'));
select is(cash_balance, 85000.00::numeric(18,2), 'license costs 25000: 110000 - 25000')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- Gating and validation.
insert into r values ('lvl', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 100, 1000));
select is(receipt ->> 'reason', '100× unlocks at level 10', 'high leverage gated by level')
  from r where label = 'lvl';
insert into r values ('tiny', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 50));
select is(receipt ->> 'reason', 'minimum margin is $100', 'dust margins rejected')
  from r where label = 'tiny';

-- ---------------------------------------------------------------------------
-- Open long 10x with $1,000 margin.
-- ---------------------------------------------------------------------------
insert into r values ('open1', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 1000));
select is(receipt ->> 'status', 'opened', 'position opens') from r where label = 'open1';
select is(cash_balance, 84500.00::numeric(18,2),
  'margin debited, use_leverage mission paid: 85000 - 1000 + 500')
  from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(quantity, round(1000 * 10 / 182.6825, 4),
  'sized as margin x leverage / entry')
  from leveraged_positions where status = 'open';
select is(liquidation_price, round(182.6825 * 0.9, 4),
  'long 10x liquidates 10% below entry')
  from leveraged_positions where status = 'open';
select is(status, 'completed', 'use_leverage mission completed')
  from user_missions where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
   and mission_id = (select id from missions where code = 'use_leverage');
select ok((select flow from assets where symbol = 'GOGL') > 9000,
  'full notional pushed into market flow');

-- Net worth marks leveraged equity (tick recomputes both sides identically).
select game.market_tick();
select is(
  (select net_worth from profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  (select (p.cash_balance + coalesce((
      select sum(greatest(0, lp.margin +
                 lp.quantity * (a.current_price * (1 - a.spread / 2) - lp.entry_price)))
        from leveraged_positions lp join assets a on a.id = lp.asset_id
       where lp.user_id = p.id and lp.status = 'open'), 0))::numeric(18,2)
     from profiles p where p.id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'net worth includes open leveraged equity');

-- ---------------------------------------------------------------------------
-- Protection on a leveraged position.
-- ---------------------------------------------------------------------------
insert into r values ('sl_liq', set_leveraged_protection(
  (select (receipt ->> 'position_id')::uuid from r where label = 'open1'), null, 160));
select is(receipt ->> 'reason',
  'stop loss must sit between the liquidation price and the current price',
  'SL below liquidation rejected') from r where label = 'sl_liq';
insert into r values ('tp_low', set_leveraged_protection(
  (select (receipt ->> 'position_id')::uuid from r where label = 'open1'), 100, null));
select is(receipt ->> 'reason', 'take profit must be above the current price',
  'TP below mark rejected') from r where label = 'tp_low';
insert into r values ('prot', set_leveraged_protection(
  (select (receipt ->> 'position_id')::uuid from r where label = 'open1'), 190, 170));
select is(receipt ->> 'status', 'protected', 'TP/SL set on position')
  from r where label = 'prot';

-- In range: nothing fires.
update public.assets set current_price = 182.50 where symbol = 'GOGL';
select game.process_leveraged_positions();
select is(status, 'open', 'holds while price is between SL and TP')
  from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1');

-- Price falls to 170: SL fires at the bid (169.83), above liquidation.
update public.assets set current_price = 170 where symbol = 'GOGL';
select game.process_leveraged_positions();
select is(status, 'closed', 'stop loss closed the position')
  from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1');
select is(close_reason, 'stop_loss', 'close reason recorded')
  from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1');
select is(realized_pnl,
  (select round(quantity * (169.8300 - entry_price), 2) from leveraged_positions
    where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1')),
  'loss realized at the live bid') from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1');
-- cash = 84500 (post-open) + margin back (1000) + realized loss
select is(cash_balance,
  (select (85500.00 + round(quantity * (169.8300 - entry_price), 2))::numeric(18,2)
     from leveraged_positions
    where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open1')),
  'margin returned minus the loss') from profiles
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- ---------------------------------------------------------------------------
-- Liquidation: reopen, crash below the liquidation price, lose the margin.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 182.50, flow = 0 where symbol = 'GOGL';
insert into r values ('open2', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'long', 10, 1000));
update public.assets set current_price = 160 where symbol = 'GOGL';
select game.process_leveraged_positions();
select is(status, 'liquidated', 'crash through liquidation liquidates')
  from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open2');
select is(realized_pnl, -1000.00::numeric(18,2),
  'loss capped at the posted margin') from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'open2');
select is(
  (select cash_delta from transactions
    where type = 'margin_close'
      and ref_id = (select receipt ->> 'position_id' from r where label = 'open2')),
  0.00::numeric(18,2), 'liquidation returns nothing — but never goes negative');

-- ---------------------------------------------------------------------------
-- Short: profit when the price falls.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 182.50, flow = 0 where symbol = 'GOGL';
insert into r values ('short', open_leveraged_position(
  (select id from assets where symbol = 'GOGL'), 'short', 5, 1000));
select is(receipt ->> 'status', 'opened', 'shorts open') from r where label = 'short';
update public.assets set current_price = 175 where symbol = 'GOGL';
insert into r values ('shortclose', close_leveraged_position(
  (select (receipt ->> 'position_id')::uuid from r where label = 'short')));
select is(close_reason, 'manual', 'manual close recorded')
  from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'short');
select is(realized_pnl,
  (select round(quantity * (entry_price - 175.1750), 2) from leveraged_positions
    where id = (select (receipt ->> 'position_id')::uuid from r where label = 'short')),
  'short profits as price falls (exit at the ask)') from leveraged_positions
 where id = (select (receipt ->> 'position_id')::uuid from r where label = 'short');
select is(
  (select cash_delta from transactions
    where type = 'margin_close'
      and ref_id = (select receipt ->> 'position_id' from r where label = 'short')),
  (select (1000.00 + realized_pnl)::numeric(18,2) from leveraged_positions
    where id = (select (receipt ->> 'position_id')::uuid from r where label = 'short')),
  'proceeds = margin + profit, through the ledger');

select is((select count(*)::int from game.reconcile_ledger()), 0,
  'ledger reconciles after margin flows');

select * from finish();
rollback;
