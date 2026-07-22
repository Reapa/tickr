-- ============================================================================
-- Migration 33: livelier, tradeable markets (faster mean-reversion + more vol)
--
-- Problem: charts were flat between news "cliffs" — you couldn't make a 10%
-- move by trading, only by catching an event. Root cause: fair_value reverted
-- to its anchor with coefficient ~2 in game-year units, i.e. a ~7 REAL-DAY
-- reversion time. Over a play session that behaves like a near-frozen random
-- walk with tiny steps (measured organic hourly vol ≈ 0.7%), so the price sits
-- still until a news shock jolts it.
--
-- Fix (validated by OU simulation of the exact process):
--   1. Speed up fair_value → anchor mean-reversion dramatically, so price
--      OSCILLATES in a bounded, tradeable band within ~1-2 hours instead of
--      random-walking for days. Bounded = no runaway crashes/moons; the slow
--      hidden anchor (migration 28) still sets the long-run centre.
--   2. Raise base_volatility per class to set each band width:
--        stocks ±6%, companies ±5%, crypto ±16%, real-estate ±3.5%, forex ±0.9%.
--   Net organic hourly vol ≈ 2.5-3.5% for stocks, intra-hour ranges ~10%, so a
--   well-timed 10% trade is achievable but not trivial — and news now adds on
--   top of a live market instead of being the only thing that moves it.
-- ============================================================================

-- Band widths: scale each class's tradeable volatility (preserves the relative
-- calm/wild ordering between assets within a class).
update public.assets set base_volatility = round((base_volatility *
  case class_id when 'stocks'      then 3.5
                when 'companies'   then 5.0
                when 'crypto'      then 1.6
                when 'real_estate' then 2.5
                when 'forex'       then 1.5
                else 1.0 end)::numeric, 4);

-- ----------------------------------------------------------------------------
-- Tick: identical to migration 31 (earnings calendar) EXCEPT the fair_value
-- mean-reversion coefficients (the `case class_id` inside adv2) are raised from
-- single digits to 100-250, turning the slow random walk into a fast, bounded
-- oscillation around the anchor.
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

  -- 0. Resolve any due earnings into live news (before shocks are applied).
  perform game.resolve_scheduled_events();

  -- 1. Maybe spawn news, and maybe schedule a future earnings announcement.
  if random() < v_spawn_prob then
    perform game.spawn_market_event();
  end if;
  if random() < game.config_numeric('earnings_schedule_probability') then
    perform game.schedule_earnings_event();
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
           -- Fair value mean-reverts to the (moving) anchor. Fast coefficients
           -- (real-time reversion ~1-2h) keep it a bounded, tradeable oscillation.
           greatest(0.01, old_fair * exp(
             (case class_id when 'forex' then 150.0 when 'real_estate' then 100.0
                            when 'crypto' then 100.0 else 250.0 end)
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
