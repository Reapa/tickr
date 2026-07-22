-- ============================================================================
-- Migration 28: bounded-but-unpredictable market (hidden anchor) + price reset
--
-- The old engine let fair_value random-walk with no gravity, and multiplicative
-- news shocks dragged it down over time — so high-vol assets decayed toward
-- zero and forex wandered off real-world rates. This replaces it with a 3-layer
-- model, all layers HIDDEN from clients (assets only grants current_price):
--
--   reference_price : fixed realistic centre (the seed value)
--   anchor_price    : slow "fundamental" that wanders around the reference —
--                     weakly for stocks/crypto (target never knowable, so no
--                     exploitable "reverts to X" trade), tightly for forex
--   fair_value      : mean-reverts to the moving anchor + tradeable vol, no drag
--   current_price   : tracks fair_value + order flow (unchanged, the only public one)
--
-- Net: prices stay bounded (can't crash to 0 or moon forever) but the
-- reversion target is a moving hidden value, so the market stays competitive.
-- Also resets every asset to a realistic price to undo the drift.
-- ============================================================================

-- Hidden layers (not in the assets column-grant, so clients never see them).
alter table public.assets
  add column reference_price numeric,
  add column anchor_price    numeric;

-- Any asset (seed or future) starts with reference/anchor = its opening price.
create or replace function game.init_asset_anchor()
returns trigger language plpgsql as $$
begin
  new.reference_price := coalesce(new.reference_price, new.current_price);
  new.anchor_price    := coalesce(new.anchor_price, new.current_price);
  return new;
end;
$$;
drop trigger if exists assets_init_anchor on public.assets;
create trigger assets_init_anchor before insert on public.assets
  for each row execute function game.init_asset_anchor();

-- Reset existing (already-drifted) assets to realistic values, and seed the
-- hidden layers. Values match supabase/seed.sql.
update public.assets a set
     current_price = s.p, fair_value = s.p, anchor_price = s.p,
     reference_price = s.p, flow = 0
  from (values
    ('GOGL',182.50),('ENVD',64.20),('NTDO',28.75),('AMZM',41.10),
    ('SLCT',55.40),('TSLR',33.80),('XOFF',88.90),
    ('GMSX',112.30),('VIZA',74.60),('GEKO',47.20),
    ('SBRW',36.50),('KOKA',61.80),('NIKY',94.40),
    ('MDNA',52.70),('JNJN',77.90),('PFZR',103.60),
    ('DWTN',1250.00),('SUBH',640.00),('MALL',310.00),('WRHS',920.00),('ISLE',480.00),
    ('BTCN',67500.00),('ETHR',3520.00),('SOLM',152.00),('DOGR',0.1250),
    ('EURUSD',1.0850),('GBPUSD',1.2700),('USDJPY',148.5000),('AUDUSD',0.6550),
    ('USDZAR',18.5000),('USDCAD',1.3600),('USDINR',83.5000),
    ('CO-CAI',50000.00),('CO-SPCY',85000.00),('CO-TED',120000.00)
  ) as s(symbol, p)
 where a.symbol = s.symbol;

-- Catch-all for anything not listed above.
update public.assets set
     reference_price = coalesce(reference_price, current_price),
     anchor_price    = coalesce(anchor_price, current_price)
 where reference_price is null or anchor_price is null;

-- Clear the drifted price history so charts restart from the corrected prices.
delete from public.price_ticks;

-- ----------------------------------------------------------------------------
-- Rewritten tick. Only step 3 (the advance) changes; everything else is as in
-- migration 8.
-- ----------------------------------------------------------------------------
create or replace function game.market_tick()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_tick_seconds numeric := game.config_numeric('tick_seconds');
  v_year_seconds numeric := game.config_numeric('seconds_per_game_year');
  v_halflife     numeric := game.config_numeric('flow_halflife_seconds');
  v_spawn_prob   numeric := game.config_numeric('event_spawn_probability');
  v_retention    numeric := game.config_numeric('price_tick_retention_days');
  v_dt           numeric;
  v_decay        numeric;
begin
  if not pg_try_advisory_xact_lock(hashtext('game.market_tick')) then
    return;
  end if;

  v_dt    := v_tick_seconds / v_year_seconds;
  v_decay := power(0.5, v_tick_seconds / v_halflife);

  -- 1. Maybe spawn news.
  if random() < v_spawn_prob then
    perform game.spawn_market_event();
  end if;

  -- 2. Apply pending fair-value shocks exactly once per event.
  with pending as (
    select id, scope, asset_id, sector, fv_impact
      from public.market_events
     where not applied and starts_at <= now()
     for update
  ),
  shocked as (
    update public.assets a
       set fair_value = greatest(0.01, a.fair_value * (1 + p.fv_impact))
      from pending p
     where a.is_active and game.is_market_open(a.market_hours)
       and (   (p.scope = 'asset'  and a.id = p.asset_id)
            or (p.scope = 'sector' and a.sector = p.sector)
            or  p.scope = 'market')
     returning p.id
  )
  update public.market_events e
     set applied = true
   where e.id in (select id from pending);

  -- 3. Advance every active asset through the 3-layer model.
  with vol as (
    select a.id as asset_id,
           coalesce(exp(sum(ln(e.vol_multiplier))), 1) as mult
      from public.assets a
      join public.market_events e
        on e.starts_at <= now() and e.ends_at > now() and e.vol_multiplier > 1
       and (   (e.scope = 'asset'  and e.asset_id = a.id)
            or (e.scope = 'sector' and e.sector = a.sector)
            or  e.scope = 'market')
     group by a.id
  ),
  draws as (
    select a.id as asset_id, game.random_normal() as z, game.random_normal() as z2
      from public.assets a
     where a.is_active and game.is_market_open(a.market_hours)
  ),
  adv as (
    select a.id as asset_id, a.class_id, a.current_price, a.reversion_speed,
           a.impact_coef, a.liquidity, a.fair_value as old_fair,
           a.flow * v_decay as new_flow,
           a.base_volatility * coalesce(v.mult, 1) as sigma,
           d.z as z,
           -- Anchor: own drift + low noise, weakly pulled to the reference.
           greatest(0.0001, coalesce(a.anchor_price, a.fair_value) * exp(
             (a.drift
              + (case a.class_id when 'forex' then 3.0 when 'real_estate' then 0.5
                                 when 'crypto' then 0.3 else 0.4 end)
                * ln(coalesce(a.reference_price, a.fair_value)
                     / greatest(0.0001, coalesce(a.anchor_price, a.fair_value)))
             ) * v_dt
             + (case a.class_id when 'forex' then 0.02 when 'crypto' then 0.25
                                when 'real_estate' then 0.05 else 0.10 end)
               * sqrt(v_dt) * d.z2)) as new_anchor
      from draws d
      join public.assets a on a.id = d.asset_id
      left join vol v on v.asset_id = d.asset_id
  ),
  adv2 as (
    select adv.*,
           -- Fair value mean-reverts to the (moving) anchor with tradeable vol.
           greatest(0.01, old_fair * exp(
             (case class_id when 'forex' then 6.0 when 'real_estate' then 3.0
                            when 'crypto' then 1.5 else 2.0 end)
               * ln(new_anchor / greatest(0.01, old_fair)) * v_dt
             + sigma * sqrt(v_dt) * z)) as new_fair
      from adv
  )
  update public.assets a
     set anchor_price = adv2.new_anchor,
         fair_value   = adv2.new_fair,
         flow         = adv2.new_flow,
         current_price = greatest(0.01,
           adv2.current_price + adv2.reversion_speed * (
             adv2.new_fair * (1 + adv2.impact_coef * tanh(adv2.new_flow / adv2.liquidity))
             - adv2.current_price)),
         updated_at = now()
    from adv2
   where a.id = adv2.asset_id;

  -- 3b. Triggered orders + leveraged liquidations/TP/SL at the new prices.
  perform game.execute_triggered_orders();
  perform game.process_leveraged_positions();

  -- 4. Record public ticks; prune history beyond retention.
  insert into public.price_ticks (asset_id, price)
  select id, current_price from public.assets
   where is_active and game.is_market_open(market_hours);

  delete from public.price_ticks
   where tick_at < now() - make_interval(days => v_retention::int);

  -- 5. Refresh net worth: cash + marked holdings + leveraged equity.
  update public.profiles p
     set net_worth = p.cash_balance
       + coalesce((select sum(h.quantity * a.current_price)
                     from public.holdings h
                     join public.assets a on a.id = h.asset_id
                    where h.user_id = p.id), 0)
       + coalesce((select sum(greatest(0, lp.margin +
                     case when lp.side = 'long'
                          then lp.quantity * (a.current_price * (1 - a.spread / 2)
                                              - lp.entry_price)
                          else lp.quantity * (lp.entry_price
                                              - a.current_price * (1 + a.spread / 2))
                     end))
                     from public.leveraged_positions lp
                     join public.assets a on a.id = lp.asset_id
                    where lp.user_id = p.id and lp.status = 'open'), 0);

  insert into public.net_worth_history (user_id, net_worth)
  select id, net_worth from public.profiles;

  delete from public.net_worth_history
   where tick_at < now() - make_interval(days => v_retention::int);

  -- 6. Competition upkeep.
  perform game.update_season_scores();
  perform game.resolve_seasons();
  perform game.resolve_challenges();
end;
$$;
