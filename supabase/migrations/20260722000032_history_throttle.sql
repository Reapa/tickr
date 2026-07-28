-- ============================================================================
-- Net-worth history: 12x fewer rows, and a chart payload that doesn't scale
-- with how long you've played
--
-- `game.market_tick` wrote one net_worth_history row PER PROFILE PER TICK. At a
-- 5-second tick that is 17,280 rows per player per day — 120,960 over the
-- 7-day retention window. It is the only table in the system whose growth is
-- multiplied by the player count, and it was the fastest-growing thing here.
--
-- Worse, the Portfolio chart fetched the ENTIRE week with no limit
-- (`gte(tick_at, now-7d)`, no `.limit()`), so a player who had been active for
-- a week downloaded ~121,000 JSON objects — several megabytes — every time
-- they opened the Portfolio tab, on a phone, to draw a chart a few hundred
-- pixels wide.
--
-- Five-second resolution on a seven-day chart was never meaningful; it is far
-- below one pixel per point. Two changes:
--
--   1. Write history at most once per `net_worth_history_seconds` (default 60),
--      not every tick. Same chart, ~1/12th the rows. Retention pruning moves
--      onto the same throttle rather than firing 17,280 times a day to delete
--      a handful of rows each time.
--
--   2. New `public.get_net_worth_series(hours, buckets)` time-buckets
--      server-side and returns at most `buckets` points however long the range,
--      so the payload is bounded by the chart's resolution instead of by the
--      player's history.
--
-- Also, structurally: the net-worth block is lifted out of market_tick into
-- `game.refresh_net_worth()`. That block has now been carried through six
-- migrations by copying the entire 200-line tick body each time (21 -> 24 ->
-- 25 -> 27 -> 28 -> here), purely because the net-worth calculation lives
-- inside it. Every future change to what counts toward net worth — and there
-- will be more — now touches a 40-line function instead of re-copying the
-- engine that also drives prices, stop-losses, liquidations and seasons.
-- ============================================================================

insert into public.game_config (key, value, description) values
  ('net_worth_history_seconds', '60',
   'Minimum seconds between net-worth history snapshots. The chart spans days, '
   'so tick-resolution samples were millions of rows nobody could see.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- The net-worth split, lifted verbatim out of market_tick (migration 28).
--
-- trading_net_worth drives season scoring, so it must exclude anything that is
-- not trading: business ventures sit on their own track, and arcade winnings
-- are subtracted here and added back on the business side so slots can never
-- move a season standing in either direction.
-- ----------------------------------------------------------------------------
create or replace function game.refresh_net_worth()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
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
                            where lp.user_id = p2.id and lp.status = 'open'), 0)
               - coalesce((select ua.net_pnl from public.user_arcade ua
                            where ua.user_id = p2.id), 0) as trading,
             coalesce((select sum(case
                             when uc.status = 'public' and uc.public_asset_id is not null
                             then uc.founder_shares * coalesce(pa.current_price, 0)
                             else uc.valuation end)
                         from public.user_companies uc
                         left join public.assets pa on pa.id = uc.public_asset_id
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0)
             + coalesce((select sum(pr.value) from public.user_properties pr
                          where pr.user_id = p2.id and pr.status = 'owned'), 0)
             + coalesce((select uf.gear_value from public.user_fishery uf
                          where uf.user_id = p2.id), 0)
             + coalesce((select ua.net_pnl from public.user_arcade ua
                          where ua.user_id = p2.id), 0) as business
        from public.profiles p2
    ) calc
   where calc.id = p.id;
end $$;

-- ----------------------------------------------------------------------------
-- Snapshot + prune, both throttled. Everyone is snapshotted together, so one
-- indexed existence check answers "is a snapshot due?" for the whole table.
-- ----------------------------------------------------------------------------
create or replace function game.snapshot_net_worth()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_every     numeric := coalesce(game.config_numeric('net_worth_history_seconds'), 60);
  v_retention numeric := game.config_numeric('price_tick_retention_days');
begin
  if exists (select 1 from public.net_worth_history
              where tick_at > now() - make_interval(secs => v_every)) then
    return;
  end if;

  insert into public.net_worth_history (user_id, net_worth)
  select id, net_worth from public.profiles;

  -- Retention pruning rides the same throttle: deleting a few rows 17,280
  -- times a day was the same total work spread over 288x the statements.
  delete from public.net_worth_history
   where tick_at < now() - make_interval(days => v_retention::int);
  delete from public.price_ticks
   where tick_at < now() - make_interval(days => v_retention::int);
end $$;

-- ----------------------------------------------------------------------------
-- A bounded chart series. Buckets server-side so the payload is set by the
-- chart's resolution, not by how long the player has been playing.
-- ----------------------------------------------------------------------------
create or replace function public.get_net_worth_series(
  p_hours   int default 168,
  p_buckets int default 240
)
returns table (tick_at timestamptz, net_worth numeric)
language sql
stable
security definer
set search_path = public, game
as $$
  with bounds as (
    select greatest(least(p_hours, 24 * 30), 1) as hours,
           greatest(least(p_buckets, 1000), 10) as buckets
  ),
  span as (
    select hours, buckets,
           greatest(hours * 3600.0 / buckets, 1) as secs
      from bounds
  )
  select to_timestamp(floor(extract(epoch from h.tick_at) / s.secs) * s.secs) as tick_at,
         round(avg(h.net_worth), 2) as net_worth
    from public.net_worth_history h, span s
   where h.user_id = auth.uid()
     and h.tick_at > now() - make_interval(hours => s.hours)
   group by 1
   order by 1;
$$;

grant execute on function public.get_net_worth_series(int, int) to authenticated;

comment on function public.get_net_worth_series(int, int) is
  'Time-bucketed net-worth series for the portfolio chart. Returns at most '
  'p_buckets points regardless of range, so the payload never grows with the '
  'length of a player''s history.';

-- ----------------------------------------------------------------------------
-- The tick, now delegating the net-worth block. Redefined from migration 28;
-- the price/event/trigger engine above is byte-identical.
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

  -- Net worth every tick (positions must mark live); history on a throttle.
  perform game.refresh_net_worth();
  perform game.snapshot_net_worth();

  perform game.update_season_scores();
  perform game.resolve_seasons();
  perform game.resolve_challenges();
end;
$$;
