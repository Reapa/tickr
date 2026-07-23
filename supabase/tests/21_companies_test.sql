-- ============================================================================
-- Companies Phase 1: found a company, business income accrues + collects, and
-- the net-worth split (trading excludes the business; total conserves the
-- cash → equity swap).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

-- Hold the tick lock for the whole test; our own market_tick() calls re-enter it
-- (advisory locks are re-entrant per session) while the cron is kept out.
select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(10);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        'authenticated', 'authenticated', 'dan@example.test',
        '{"display_name": "Dan"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "role": "authenticated"}', true);

select ok((select is_enabled from public.asset_classes where id = 'companies'),
  'companies class is enabled');

-- Fund the player to $210k (cash-in ledger row → trigger updates cash_balance).
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'mission_reward', 200000, 'test');

create temp table cr (label text primary key, receipt jsonb);

-- Founding is gated on the class unlock.
insert into cr values ('locked', public.found_company('Testco', 'software', 60000));
select is(cr.receipt ->> 'status', 'locked',
  'cannot found a company before unlocking the class') from cr where label = 'locked';

insert into public.user_asset_class_unlocks (user_id, class_id)
values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'companies');

insert into cr values ('found', public.found_company('Testco', 'software', 60000));
select is(cr.receipt ->> 'status', 'founded', 'company founded after unlock')
  from cr where label = 'found';
select is((select cash_balance from public.profiles
            where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  150000.00::numeric, 'startup capital is debited from cash (210k - 60k)');
select is((select valuation from public.user_companies
            where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  60000.00::numeric, 'a founded company is worth the capital put in');

-- Refresh net worth via a tick and check the split. No holdings, so trading is
-- pure cash; total conserves the cash → equity swap.
select game.market_tick();
select is((select business_equity from public.profiles
            where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  60000.00::numeric, 'business_equity reflects the company valuation');
select is((select net_worth from public.profiles
            where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  210000.00::numeric, 'total net worth is conserved across founding (cash+company)');
select is((select trading_net_worth from public.profiles
            where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  150000.00::numeric, 'trading net worth (drives seasons) excludes the company');

-- Business revenue accrues into the unified income bucket and collects.
update public.user_income
   set last_accrued_at = now()
     - (game.config_numeric('seconds_per_game_year') || ' seconds')::interval
 where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
select game.accrue_income('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
select is((select pending_business from public.user_income
            where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  2727.27::numeric, 'one game-year of business revenue accrues (60000 / 22)');

insert into cr values ('collect', public.collect_income());
select is((cr.receipt ->> 'business')::numeric, 2727.27::numeric,
  'collect_income sweeps the business bucket') from cr where label = 'collect';

select * from finish();
rollback;
