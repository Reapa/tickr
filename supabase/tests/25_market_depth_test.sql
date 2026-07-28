-- ============================================================================
-- Market depth: the square-root impact law, the recalibrated book, the
-- leverage flow factor, and the flow clamp.
--
-- Regression target: a $200k order (spot or 50x) used to saturate the impact
-- curve and move a blue chip 4-5% in one burst.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));
update public.game_config set value = 'true' where key = 'markets_always_open';
-- Silence the news engine: the end-to-end assertions below measure how far
-- ORDER FLOW moves a price, and a stray earnings shock would drown it out.
update public.game_config set value = '0'
 where key in ('event_spawn_probability', 'earnings_schedule_probability');

select plan(19);

-- ---------------------------------------------------------------------------
-- The impact curve itself.
-- ---------------------------------------------------------------------------
select is(game.flow_impact(0, 20000000, 0.05), 0::numeric,
  'no flow, no impact');

select is(game.flow_impact(-500000, 20000000, 0.05),
          -game.flow_impact(500000, 20000000, 0.05),
  'impact is symmetric in direction');

select ok(game.flow_impact(1e15, 20000000, 0.05) <= 0.05,
  'impact is hard-bounded by impact_coef even at absurd size');

select ok(game.flow_impact(200000, 20000000, 0.05) < 0.0075,
  'a $200k order moves a deep stock less than 0.75%');

select ok(game.flow_impact(200000, 20000000, 0.05) > 0.002,
  '...but more than nothing — size is still felt');

-- Concavity: 100x the flow must NOT be 100x the impact. Square-root law puts
-- it near 10x; anything close to linear means the curve regressed.
select ok(
  game.flow_impact(10000000, 20000000, 0.05)
    < 20 * game.flow_impact(100000, 20000000, 0.05),
  'impact is concave in size, not linear');

select ok(
  game.flow_impact(400000, 20000000, 0.05)
    > game.flow_impact(200000, 20000000, 0.05),
  'impact is strictly increasing in size');

-- ---------------------------------------------------------------------------
-- The book was recalibrated to real reference notionals.
-- ---------------------------------------------------------------------------
select ok((select min(liquidity) from assets where class_id = 'stocks') > 5000000,
  'every stock has at least $5M of reference depth');

select ok((select liquidity from assets where symbol = 'GMSX')
        > (select liquidity from assets where symbol = 'MDNA'),
  'relative depth survives: the bank is deeper than the biotech');

-- ---------------------------------------------------------------------------
-- End to end: a $200k market buy no longer detonates a blue chip.
-- ---------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'authenticated', 'authenticated', 'whale@example.test',
        '{"display_name": "Whale"}'::jsonb);
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "role": "authenticated"}', true);
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 500000, 'test');

-- Pin GOGL and freeze the random walk so only order flow can move the price.
update public.assets
   set current_price = 200, fair_value = 200, anchor_price = 200,
       reference_price = 200, base_volatility = 0.0001, drift = 0, flow = 0
 where symbol = 'GOGL';

select place_market_order((select id from assets where symbol = 'GOGL'),
                          'buy', round(200000 / 200.2, 4));

-- Let the price converge on the flow-shifted target (reversion_speed 0.25/tick).
select game.market_tick() from generate_series(1, 20);

select ok((select current_price from assets where symbol = 'GOGL') < 202,
  'a $200k buy moves a $200 blue chip under 1% (was ~4.2%)');

select ok((select current_price from assets where symbol = 'GOGL') > 200,
  '...and it does move it up — flow still has a real, visible effect');

-- ---------------------------------------------------------------------------
-- Leveraged flow enters the book scaled, not at face notional.
-- ---------------------------------------------------------------------------
update public.assets set current_price = 200, fair_value = 200, flow = 0
 where symbol = 'GOGL';
insert into public.transactions (user_id, type, cash_delta, ref_type)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'mission_reward', 300000, 'test');
select purchase_asset_class_unlock('margin');
-- level is generated from xp: floor(sqrt(xp/100)) + 1, so 1600 xp = level 5 = 50x.
update public.profiles set xp = 2000 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

select open_leveraged_position((select id from assets where symbol = 'GOGL'),
                               'long', 50, 4000);

select is(
  (select round(flow, 2) from assets where symbol = 'GOGL'),
  (select round(quantity * entry_price * game.config_numeric('leverage_flow_factor'), 2)
     from leveraged_positions where status = 'open'),
  '50x on $4k margin pushes scaled notional, not the full $200k');

-- Closing unwinds at the same scale, so a round trip nets to ~zero pressure
-- instead of leaving a crater the size of the whole position.
select close_leveraged_position((select id from leveraged_positions
                                  where status = 'open' limit 1));
select ok(abs((select flow from assets where symbol = 'GOGL')) < 2000,
  'a round trip leaves the book roughly where it found it');

-- ---------------------------------------------------------------------------
-- The clamp: flow cannot sit pinned far beyond the cap.
-- ---------------------------------------------------------------------------
update public.assets set flow = 1e12 where symbol = 'GOGL';
select game.market_tick();
select ok(
  (select flow from assets where symbol = 'GOGL')
    <= (select liquidity * game.config_numeric('flow_cap_multiple')
          from assets where symbol = 'GOGL'),
  'runaway flow is clamped to the configured multiple of depth');

-- ---------------------------------------------------------------------------
-- Depth is legible to players, and the parameters behind it still are not.
-- ---------------------------------------------------------------------------
select is((select depth_tier from assets where symbol = 'GMSX'), 'deep',
  'the mega-cap bank reads as a deep book');
select is((select depth_tier from assets where symbol = 'DOGR'), 'thin',
  'the memecoin reads as a thin book');

set local role authenticated;
select throws_ok('select liquidity from assets limit 1', '42501', null,
  'book depth is legible but the liquidity parameter stays hidden');
select lives_ok('select depth_tier from assets limit 1',
  'depth_tier is readable by players');
reset role;

select ok(
  public.estimate_price_impact((select id from assets where symbol = 'GOGL'),
                               'buy', 200000) < 0.0075,
  'the order ticket can quote impact before the player commits');

select * from finish();
rollback;
