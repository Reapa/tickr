-- ============================================================================
-- Migration 8: the simulation engine — game.market_tick()
--
-- Every tick (default 5s, driven by pg_cron or the admin-tick edge function):
--   1. maybe spawn a news event from event_templates
--   2. apply pending fair-value shocks from newly started events (once each)
--   3. advance every active asset:
--        z          = N(0,1)
--        sigma_eff  = base_volatility * Π(active event vol multipliers)
--        fair_value = fair_value * exp((drift - sigma_eff²/2)dt + sigma_eff·√dt·z)
--        flow       = flow * 2^(-tick/flow_halflife)
--        target     = fair_value * (1 + impact_coef · tanh(flow / liquidity))
--        price      = price + reversion_speed · (target - price)
--   4. write price_ticks (the public Realtime feed) and prune old ones
--   5. refresh profiles.net_worth = cash + Σ qty·price
--   6. update season scores; resolve due seasons and challenges
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Event spawning: weighted template pick, random target, randomized impact.
-- ----------------------------------------------------------------------------
create or replace function game.spawn_market_event()
returns void
language plpgsql
as $$
declare
  v_tpl    public.event_templates%rowtype;
  v_asset  public.assets%rowtype;
  v_sector text;
  v_impact numeric;
  v_headline text;
  v_body     text;
begin
  -- Weighted random template.
  select t.* into v_tpl
    from public.event_templates t
   order by -ln(1 - random()) / t.weight   -- exponential-race weighted sampling
   limit 1;
  if not found then return; end if;

  v_impact := round(
    (v_tpl.fv_impact_min + random() * (v_tpl.fv_impact_max - v_tpl.fv_impact_min))::numeric,
    4);

  if v_tpl.scope = 'asset' then
    select a.* into v_asset from public.assets a
     where a.is_active and (v_tpl.class_id is null or a.class_id = v_tpl.class_id)
     order by random() limit 1;
    if not found then return; end if;
    v_sector := v_asset.sector;
  elsif v_tpl.scope = 'sector' then
    select a.sector into v_sector from public.assets a
     where a.is_active order by random() limit 1;
    if not found then return; end if;
  end if;

  v_headline := replace(replace(replace(v_tpl.headline_template,
                  '{name}',   coalesce(v_asset.name, '')),
                  '{symbol}', coalesce(v_asset.symbol, '')),
                  '{sector}', coalesce(initcap(replace(v_sector, '_', ' ')), ''));
  v_body := replace(replace(replace(v_tpl.body_template,
                  '{name}',   coalesce(v_asset.name, '')),
                  '{symbol}', coalesce(v_asset.symbol, '')),
                  '{sector}', coalesce(initcap(replace(v_sector, '_', ' ')), ''));

  insert into public.market_events
    (template_code, scope, asset_id, sector, headline, body, sentiment,
     fv_impact, vol_multiplier, starts_at, ends_at)
  values
    (v_tpl.code, v_tpl.scope, v_asset.id, v_sector, v_headline, v_body,
     case when v_impact > 0.001 then 'positive'
          when v_impact < -0.001 then 'negative'
          else 'neutral' end,
     v_impact, v_tpl.vol_multiplier,
     now(), now() + make_interval(secs => v_tpl.duration_seconds));
end;
$$;

-- ----------------------------------------------------------------------------
-- The tick.
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
  -- Never run two ticks concurrently (slow tick + eager scheduler).
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
     where a.is_active
       and (   (p.scope = 'asset'  and a.id = p.asset_id)
            or (p.scope = 'sector' and a.sector = p.sector)
            or  p.scope = 'market')
     returning p.id
  )
  update public.market_events e
     set applied = true
   where e.id in (select id from pending);

  -- 3. Advance every active asset.
  with vol as (
    -- product of active event volatility multipliers per asset
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
    select a.id as asset_id, game.random_normal() as z
      from public.assets a
     where a.is_active
  )
  update public.assets a
     set fair_value = greatest(0.01,
           a.fair_value * exp(
             (a.drift - power(a.base_volatility * coalesce(v.mult, 1), 2) / 2) * v_dt
             + a.base_volatility * coalesce(v.mult, 1) * sqrt(v_dt) * d.z)),
         flow = a.flow * v_decay,
         current_price = greatest(0.01,
           a.current_price + a.reversion_speed * (
             (greatest(0.01, a.fair_value * exp(
                (a.drift - power(a.base_volatility * coalesce(v.mult, 1), 2) / 2) * v_dt
                + a.base_volatility * coalesce(v.mult, 1) * sqrt(v_dt) * d.z))
              * (1 + a.impact_coef * tanh(a.flow * v_decay / a.liquidity)))
             - a.current_price)),
         updated_at = now()
    from draws d
    left join vol v on v.asset_id = d.asset_id
   where a.id = d.asset_id;

  -- 4. Record public ticks; prune history beyond retention.
  insert into public.price_ticks (asset_id, price)
  select id, current_price from public.assets where is_active;

  delete from public.price_ticks
   where tick_at < now() - make_interval(days => v_retention::int);

  -- 5. Refresh net worth (cash + marked-to-market holdings).
  update public.profiles p
     set net_worth = p.cash_balance + coalesce(hv.value, 0)
    from (select h.user_id, sum(h.quantity * a.current_price) as value
            from public.holdings h
            join public.assets a on a.id = h.asset_id
           group by h.user_id) hv
   where hv.user_id = p.id;

  update public.profiles p
     set net_worth = p.cash_balance
   where not exists (select 1 from public.holdings h where h.user_id = p.id)
     and p.net_worth <> p.cash_balance;

  -- 6. Competition upkeep (defined in migration 10).
  perform game.update_season_scores();
  perform game.resolve_seasons();
  perform game.resolve_challenges();
end;
$$;

-- ----------------------------------------------------------------------------
-- Scheduling: pg_cron with a seconds-granularity schedule matching
-- game_config.tick_seconds. Guarded for environments without pg_cron —
-- there the admin-tick edge function (invoked by any external scheduler)
-- drives the loop instead.
-- ----------------------------------------------------------------------------
create or replace function public.admin_run_tick()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  -- service_role only (the edge function); clients cannot execute this.
  if coalesce((current_setting('request.jwt.claims', true))::jsonb ->> 'role', '')
       not in ('service_role') and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'admin_run_tick is service-role only';
  end if;
  perform game.market_tick();
end;
$$;

grant execute on function public.admin_run_tick() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'market-tick',
      (game.config_numeric('tick_seconds'))::int || ' seconds',
      $cron$ select game.market_tick(); $cron$
    );
  else
    raise notice 'pg_cron missing: schedule the admin-tick edge function externally.';
  end if;
end $$;
