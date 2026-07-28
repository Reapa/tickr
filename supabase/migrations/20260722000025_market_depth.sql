-- ============================================================================
-- Market depth: realistic price impact
--
-- PROBLEM (reported by a live player): "if I purchase stocks at 200,000 with
-- x50 leverage the market crashes or rises heavily".
--
-- Two compounding causes:
--
--   1. `liquidity` was calibrated in the tens/hundreds of thousands, but it is
--      the notional scale of the impact curve. Any order above ~2x that scale
--      saturates tanh(), so a $200k order on GOGL (liquidity 160k) already
--      produced tanh(1.25) = 0.85 -> +4.2% instantly, and ANY leveraged order
--      pinned the curve at its cap. There was no graduation between a $10k
--      trade and a $10M one.
--
--   2. Impact was LINEAR in notional until saturation. Real price impact is
--      concave — roughly proportional to sqrt(size). Linear-then-cliff means
--      the market is either indifferent or maxed out, with nothing in between.
--
--   3. A leveraged position pushed its FULL notional into the flow, so $200k of
--      margin at 50x moved the book like a $10,000,000 order — 50x the money
--      the player actually risked. Combined with (1) that pinned the cap in
--      both directions: spike on open, mirror crash on close.
--
-- FIX
--   a) Square-root impact law, still bounded:
--        impact = impact_coef * tanh( sign(flow) * sqrt(|flow| / liquidity) )
--      Concave in size (a 100x bigger order moves price 10x more, not 100x),
--      smooth everywhere, and still hard-capped at impact_coef.
--
--   b) Recalibrate `liquidity` to a real reference notional, per class,
--      preserving the hand-tuned relative depth ordering from the seed
--      (blue chips deep, memecoins thin).
--
--   c) Leveraged flow is scaled by `leverage_flow_factor` — a leveraged bet is
--      a derivative, and only the broker's hedge reaches the book. Config-
--      tunable without a migration.
--
--   d) Flow is clamped to +/- flow_cap_multiple x liquidity each tick, so a
--      burst of whale orders can't hold the curve pinned for ten minutes while
--      it decays back through six halflives.
--
-- Net effect on GOGL (liquidity 160k -> 20M, cap unchanged at 5%):
--        order            before        after
--        $10k spot         0.31%        0.11%
--        $200k spot        4.24%        0.50%
--        $200k @ 50x       5.00% (cap)  1.98%
--        $1M spot          5.00% (cap)  1.11%
-- Whales still move markets — they just no longer detonate them.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. The impact curve, as a named function so the tick and the tests agree.
-- ----------------------------------------------------------------------------
create or replace function game.flow_impact(
  p_flow      numeric,
  p_liquidity numeric,
  p_coef      numeric
)
returns numeric
language sql
immutable
as $$
  select round(
    (p_coef * tanh(
       sign(p_flow)::double precision
       * sqrt(abs(p_flow) / greatest(p_liquidity, 1))::double precision
     ))::numeric, 8);
$$;

comment on function game.flow_impact(numeric, numeric, numeric) is
  'Fractional price impact of accumulated order flow: concave (square-root) in '
  'size and hard-bounded by p_coef. p_liquidity is the reference notional at '
  'which impact reaches ~76% of the cap.';

-- ----------------------------------------------------------------------------
-- 2. Config knobs (tunable live, no migration needed).
-- ----------------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('leverage_flow_factor', '0.35',
   'Fraction of a leveraged position''s notional that reaches the order book. '
   '<1 because a derivative bet is only partially hedged into the market — '
   'stops 50x/100x from being a price-manipulation lever.'),
  ('flow_cap_multiple', '4',
   'Order flow is clamped to +/- this multiple of an asset''s liquidity, so a '
   'burst of whale orders cannot pin the impact curve for minutes on end.')
on conflict (key) do update set value = excluded.value,
                                description = excluded.description;

-- ----------------------------------------------------------------------------
-- 3. Recalibrate depth. Multiplicative per class so the seed's relative
--    ordering (blue chip deep / small cap thin) survives intact.
--
--    SEED-TIMING: on a from-scratch `supabase db reset` the assets table is
--    still empty here (assets seed AFTER migrations), so this no-ops and the
--    mirrored UPDATE at the end of seed.sql applies instead. On hosted the rows
--    already exist, so this path applies. Only ever one of the two.
-- ----------------------------------------------------------------------------
update public.assets
   set liquidity = round((liquidity *
         case class_id when 'stocks'      then 125
                       when 'real_estate' then 40
                       when 'crypto'      then 60
                       when 'forex'       then 500
                       when 'companies'   then 20
                       else 100 end)::numeric, 4);

-- New assets (e.g. a company IPO) should be born deep, not paper-thin.
alter table public.assets alter column liquidity set default 15000000;

-- ----------------------------------------------------------------------------
-- 4. Leveraged flow now enters the book scaled. Redefined from migration
--    20260721000015_leverage.sql — the ONLY changes are the two flow updates.
-- ----------------------------------------------------------------------------
create or replace function public.open_leveraged_position(
  p_asset_id uuid,
  p_side     text,
  p_leverage int,
  p_margin   numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user     uuid := auth.uid();
  v_asset    public.assets%rowtype;
  v_profile  public.profiles%rowtype;
  v_entry    numeric;
  v_qty      numeric;
  v_notional numeric;
  v_liq      numeric;
  v_id       uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_side not in ('long', 'short') then raise exception 'invalid side'; end if;
  if p_leverage not in (5, 10, 50, 100) then raise exception 'invalid leverage'; end if;
  if p_margin is null or p_margin < 100 then
    return jsonb_build_object('status', 'rejected', 'reason', 'minimum margin is $100');
  end if;

  if not game.has_class_unlock(v_user, 'margin') then
    return jsonb_build_object('status', 'rejected', 'reason', 'broker license required');
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active
  for update;
  if not found then raise exception 'unknown or inactive asset'; end if;
  if not game.is_market_open(v_asset.market_hours) then
    return jsonb_build_object('status', 'rejected', 'reason', 'market closed');
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if p_leverage > game.max_leverage_for_level(v_profile.level) then
    return jsonb_build_object('status', 'rejected',
      'reason', format('%s× unlocks at level %s', p_leverage,
                       case when p_leverage = 100 then 10 else 5 end));
  end if;
  if v_profile.cash_balance < p_margin then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash');
  end if;

  v_entry := round(v_asset.current_price *
               (1 + case when p_side = 'long' then 1 else -1 end * v_asset.spread / 2), 4);
  v_qty := round(p_margin * p_leverage / v_entry, 4);
  v_notional := round(v_qty * v_entry, 2);
  if v_notional > game.config_numeric('max_order_notional') then
    return jsonb_build_object('status', 'rejected', 'reason', 'position too large');
  end if;
  v_liq := round(v_entry * (1 + case when p_side = 'long' then -1.0 else 1.0 end
                                / p_leverage), 4);

  insert into public.leveraged_positions
    (user_id, asset_id, side, leverage, quantity, entry_price, margin, liquidation_price)
  values (v_user, p_asset_id, p_side, p_leverage, v_qty, v_entry, p_margin, v_liq)
  returning id into v_id;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'margin_open', -p_margin, 'leveraged_position', v_id::text);

  -- Leveraged flow reaches the book scaled: a derivative bet is only partially
  -- hedged into the market. Whales still move prices, but a 50x ticket no
  -- longer hits the book like fifty times the money actually at risk.
  update public.assets
     set flow = flow + case when p_side = 'long' then 1 else -1 end
                       * v_notional * game.config_numeric('leverage_flow_factor')
   where id = p_asset_id;

  update public.profiles
     set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
   where id = v_user;
  perform game.evaluate_missions(v_user);

  return jsonb_build_object('status', 'opened', 'position_id', v_id,
    'entry_price', v_entry, 'quantity', v_qty, 'notional', v_notional,
    'liquidation_price', v_liq, 'max_loss', p_margin);
end;
$$;

create or replace function game.close_leveraged_position_internal(
  p_pos    public.leveraged_positions,
  p_exit   numeric,
  p_reason text
)
returns numeric  -- proceeds returned to cash
language plpgsql
as $$
declare
  v_pnl      numeric;
  v_proceeds numeric;
  v_notional numeric := round(p_pos.quantity * p_exit, 2);
begin
  v_pnl := round(case when p_pos.side = 'long'
                      then p_pos.quantity * (p_exit - p_pos.entry_price)
                      else p_pos.quantity * (p_pos.entry_price - p_exit) end, 2);
  v_pnl := greatest(v_pnl, -p_pos.margin);
  v_proceeds := p_pos.margin + v_pnl;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (p_pos.user_id, 'margin_close', v_proceeds, 'leveraged_position',
          p_pos.id::text);

  update public.leveraged_positions
     set status = case when p_reason = 'liquidation' then 'liquidated' else 'closed' end,
         close_price = p_exit,
         realized_pnl = v_pnl,
         close_reason = p_reason,
         closed_at = now()
   where id = p_pos.id;

  -- Unwind at the same scale it was applied on open, so a round trip nets to
  -- zero pressure rather than leaving a one-sided crater.
  update public.assets
     set flow = flow + case when p_pos.side = 'long' then -1 else 1 end
                       * v_notional * game.config_numeric('leverage_flow_factor')
   where id = p_pos.asset_id;

  update public.profiles
     set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
   where id = p_pos.user_id;

  return v_proceeds;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. The tick. Redefined from migration 20260722000024_property_ownership.sql —
--    the ONLY changes are inside the price advance: the flow clamp and the
--    game.flow_impact() call replacing the raw tanh(flow / liquidity).
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
  v_flow_cap     numeric := game.config_numeric('flow_cap_multiple');
  v_dt           numeric;
  v_decay        numeric;
begin
  if not pg_try_advisory_xact_lock(hashtext('game.market_tick')) then
    return;
  end if;

  v_dt    := v_tick_seconds / v_year_seconds;
  v_decay := power(0.5, v_tick_seconds / v_halflife);

  perform game.resolve_scheduled_events();

  if random() < v_spawn_prob then
    perform game.spawn_market_event();
  end if;
  if random() < game.config_numeric('earnings_schedule_probability') then
    perform game.schedule_earnings_event();
  end if;

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
           -- Decay, then clamp: flow can never sit pinned beyond the cap.
           least(greatest(a.flow * v_decay, -v_flow_cap * a.liquidity),
                 v_flow_cap * a.liquidity) as new_flow,
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
             adv2.new_fair * (1 + game.flow_impact(adv2.new_flow, adv2.liquidity,
                                                   adv2.impact_coef))
             - adv2.current_price)),
         updated_at = now()
    from adv2
   where a.id = adv2.asset_id;

  perform game.execute_triggered_orders();
  perform game.process_leveraged_positions();

  insert into public.price_ticks (asset_id, price)
  select id, current_price from public.assets
   where is_active and game.is_market_open(market_hours);

  delete from public.price_ticks
   where tick_at < now() - make_interval(days => v_retention::int);

  -- 5. Refresh net worth. trading (cash + holdings + leverage) drives seasons;
  --    business (companies + owned property) is added for total net worth.
  update public.profiles p
     set trading_net_worth = calc.trading,
         business_equity   = calc.business,
         net_worth         = calc.trading + calc.business
    from (
      select p2.id,
             p2.cash_balance
               + coalesce((select sum(h.quantity * a.current_price)
                             from public.holdings h
                             join public.assets a on a.id = h.asset_id
                            where h.user_id = p2.id), 0)
               + coalesce((select sum(greatest(0, lp.margin +
                             case when lp.side = 'long'
                                  then lp.quantity * (a.current_price * (1 - a.spread / 2)
                                                      - lp.entry_price)
                                  else lp.quantity * (lp.entry_price
                                                      - a.current_price * (1 + a.spread / 2))
                             end))
                             from public.leveraged_positions lp
                             join public.assets a on a.id = lp.asset_id
                            where lp.user_id = p2.id and lp.status = 'open'), 0) as trading,
             coalesce((select sum(case
                             when uc.status = 'public' and uc.public_asset_id is not null
                             then uc.founder_shares * coalesce(pa.current_price, 0)
                             else uc.valuation end)
                         from public.user_companies uc
                         left join public.assets pa on pa.id = uc.public_asset_id
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0)
             + coalesce((select sum(pr.value) from public.user_properties pr
                          where pr.user_id = p2.id and pr.status = 'owned'), 0) as business
        from public.profiles p2
    ) calc
   where calc.id = p.id;

  insert into public.net_worth_history (user_id, net_worth)
  select id, net_worth from public.profiles;

  delete from public.net_worth_history
   where tick_at < now() - make_interval(days => v_retention::int);

  perform game.update_season_scores();
  perform game.resolve_seasons();
  perform game.resolve_challenges();
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Make depth legible. The player who reported this had no way to know that
--    a thin biotech and a mega-cap bank react differently to the same ticket —
--    the market just felt broken. Liquidity thresholds are per class because a
--    "deep" REIT and a "deep" forex pair are orders of magnitude apart.
--
--    depth_tier is deliberately coarse: it tells you what a real trader would
--    know from public volume data without exposing the tunable simulation
--    parameters (liquidity / impact_coef stay hidden).
-- ----------------------------------------------------------------------------
alter table public.assets
  add column depth_tier text generated always as (
    case
      when class_id = 'forex' then
        case when liquidity >= 250000000 then 'deep' else 'normal' end
      when class_id = 'crypto' then
        case when liquidity >= 20000000 then 'deep'
             when liquidity >=  6000000 then 'normal' else 'thin' end
      when class_id = 'real_estate' then
        case when liquidity >= 12000000 then 'deep'
             when liquidity >=  6000000 then 'normal' else 'thin' end
      else
        case when liquidity >= 20000000 then 'deep'
             when liquidity >=  8000000 then 'normal' else 'thin' end
    end
  ) stored;

comment on column public.assets.depth_tier is
  'Coarse, player-visible book depth. Thin names move more on the same order '
  'size — the public face of liquidity without exposing the parameter itself.';

grant select (depth_tier) on public.assets to anon, authenticated;

-- Quote the price impact of a prospective order, so a large ticket can warn
-- the player BEFORE they send it rather than surprising them afterwards.
-- Returns the fraction the price is expected to move (0.005 = +0.5%).
-- p_leveraged applies the same discount the engine applies when a derivative
-- ticket reaches the book, so the leverage sheet quotes what will actually
-- happen rather than its face notional.
create or replace function public.estimate_price_impact(
  p_asset_id  uuid,
  p_side      text,
  p_notional  numeric,
  p_leveraged boolean default false
)
returns numeric
language sql
stable
security definer
set search_path = public, game
as $$
  select coalesce((
    select abs(game.flow_impact(
             a.flow + case when p_side in ('sell', 'short') then -1 else 1 end
                      * greatest(p_notional, 0)
                      * case when p_leveraged
                             then game.config_numeric('leverage_flow_factor')
                             else 1 end,
             a.liquidity, a.impact_coef)
           - game.flow_impact(a.flow, a.liquidity, a.impact_coef))
      from public.assets a
     where a.id = p_asset_id and a.is_active), 0);
$$;

comment on function public.estimate_price_impact(uuid, text, numeric, boolean) is
  'Expected fractional price move from adding an order of this notional to the '
  'book, marginal to the flow already there. Leaks no simulation parameters.';

grant execute on function public.estimate_price_impact(uuid, text, numeric, boolean)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Existing pinned flow would take minutes to bleed off under the new curve
--    and would look like a hangover from the bug. Start clean.
-- ----------------------------------------------------------------------------
update public.assets set flow = 0 where flow <> 0;
