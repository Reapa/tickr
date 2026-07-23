-- ============================================================================
-- Property ownership Phase 3a: buy a property, rent accrues, and its value
-- lands in business_equity / total net worth but not the season figure.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
select plan(9);

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'authenticated', 'authenticated', 'bea@example.test',
        '{"display_name": "Bea"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "role": "authenticated"}', true);

insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'mission_reward', 200000, 'test');

-- A deterministic listing to buy.
insert into public.property_listings (id, name, type_id, value, rent_rate)
values ('11111111-1111-4111-8111-111111111111', 'Test Tower', 'commercial', 100000, 6000);

create temp table cr (label text primary key, receipt jsonb);

insert into cr values ('locked',
  public.buy_property('11111111-1111-4111-8111-111111111111'));
select is(cr.receipt ->> 'status', 'locked',
  'cannot buy property before unlocking real estate') from cr where label = 'locked';

insert into public.user_asset_class_unlocks (user_id, class_id)
values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'real_estate');

insert into cr values ('buy',
  public.buy_property('11111111-1111-4111-8111-111111111111'));
select is(cr.receipt ->> 'status', 'bought', 'property bought after unlock')
  from cr where label = 'buy';
select is((select cash_balance from public.profiles
            where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  110000.00::numeric, 'price is debited from cash (210k - 100k)');
select is((select value from public.user_properties
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  100000.00::numeric, 'owned property carries its value');
select is((select rent_rate from public.user_properties
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  6000.00::numeric, 'owned property carries its rent');

select game.market_tick();
select is((select business_equity from public.profiles
            where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  100000.00::numeric, 'property value is in business_equity');
select is((select net_worth from public.profiles
            where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  210000.00::numeric, 'total net worth conserved across the purchase');
select is((select trading_net_worth from public.profiles
            where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  110000.00::numeric, 'trading net worth (seasons) excludes the property');

-- One game-year of rent accrues into the pending_rent bucket.
update public.user_income
   set last_accrued_at = now()
     - (game.config_numeric('seconds_per_game_year') || ' seconds')::interval
 where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
select game.accrue_income('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select is((select pending_rent from public.user_income
            where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  6000.00::numeric, 'a full game-year of property rent accrues');

select * from finish();
rollback;
