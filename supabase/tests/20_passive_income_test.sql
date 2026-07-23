-- ============================================================================
-- Passive income: accrual math, collect sweeps to cash, idempotent when empty.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Keep the live market tick out of our pinned prices for the duration.
select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(8);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'ffffffff-ffff-4fff-8fff-ffffffffffff',
        'authenticated', 'authenticated', 'ivy@example.test',
        '{"display_name": "Ivy"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "ffffffff-ffff-4fff-8fff-ffffffffffff", "role": "authenticated"}', true);

-- The signup triggers should have created the income row.
select is((select count(*)::int from public.user_income
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  1, 'a user_income row is created on signup');

-- Pin two income assets to round numbers: a dividend stock and a rent REIT.
update public.assets set current_price = 100, income_yield = 0.05 where symbol = 'XOFF';
update public.assets set current_price = 200, income_yield = 0.05 where symbol = 'ISLE';

-- Hold 10 of each (holdings are normally trigger-materialized; a direct insert
-- is fine in-test).
insert into public.holdings (user_id, asset_id, quantity, avg_cost)
  select 'ffffffff-ffff-4fff-8fff-ffffffffffff', id, 10, current_price
    from public.assets where symbol in ('XOFF', 'ISLE');

-- Backdate the accrual clock by exactly one game-year so frac = 1: one year of
-- yield should land in one accrual. Dividends = 10*100*0.05 = 50; rent = 100.
update public.user_income
   set last_accrued_at = now()
     - (game.config_numeric('seconds_per_game_year') || ' seconds')::interval
 where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff';

select game.accrue_income('ffffffff-ffff-4fff-8fff-ffffffffffff');

select is((select pending_dividends from public.user_income
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  50.00::numeric, 'one game-year of dividends accrues (10 * 100 * 5%)');
select is((select pending_rent from public.user_income
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  100.00::numeric, 'one game-year of rent accrues (10 * 200 * 5%)');

-- Collect sweeps both buckets into cash.
create temp table cr (label text primary key, receipt jsonb);
insert into cr values ('collect', public.collect_income());

select is((cr.receipt ->> 'total')::numeric, 150.00::numeric,
  'collect_income returns the pending total') from cr where label = 'collect';
select is((select pending_dividends + pending_rent from public.user_income
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  0.00::numeric, 'pending buckets are zeroed after collect');
select is((select lifetime_income from public.user_income
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  150.00::numeric, 'lifetime_income tracks collected total');
select is((select count(*)::int from public.transactions
            where user_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
              and type = 'passive_income' and cash_delta = 150.00),
  1, 'a passive_income ledger row credits the cash');

-- Nothing left to collect is a no-op, not an error.
insert into cr values ('empty', public.collect_income());
select is(cr.receipt ->> 'status', 'empty',
  'collecting with nothing pending returns empty') from cr where label = 'empty';

select * from finish();
rollback;
