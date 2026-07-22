-- ============================================================================
-- Migration 31: earnings calendar — the anticipation → resolution loop
--
-- News today jumps straight to resolution: a shock appears and the price moves.
-- This adds the missing first half of the dopamine loop. The server schedules an
-- upcoming earnings announcement for an asset with a HIDDEN outcome (beat / miss
-- / inline, rolled now but not revealed), visible to players as a countdown
-- ("Googol reports Q3 earnings · in 3m"). Players form a thesis and position.
-- When the countdown hits zero the tick resolves it into a normal market_event —
-- real headline, sentiment, and fair-value shock — exactly like any other news.
--
-- The outcome columns (sentiment, fv_impact, vol_multiplier) are NOT granted to
-- clients, so the beat/miss stays secret until it fires. The public calendar
-- exposes only the teaser headline, quarter, and resolve time.
-- ============================================================================

create table public.scheduled_events (
  id             uuid primary key default gen_random_uuid(),
  asset_id       uuid not null references public.assets (id) on delete cascade,
  kind           text not null default 'earnings',
  headline       text not null,               -- teaser; safe to show
  quarter        text,                         -- e.g. 'Q3' (public flavour)
  scheduled_at   timestamptz not null default now(),  -- when it was announced
  resolves_at    timestamptz not null,
  status         text not null default 'scheduled'
                   check (status in ('scheduled', 'resolved', 'cancelled')),
  -- Hidden outcome (never granted to clients — this is the secret).
  sentiment      text not null check (sentiment in ('positive', 'negative', 'neutral')),
  fv_impact      numeric(8,4) not null,
  vol_multiplier numeric(8,4) not null default 1.5,
  duration_seconds int not null default 1200,
  resolved_event_id uuid references public.market_events (id),
  check (resolves_at > scheduled_at)
);

create index scheduled_events_status_idx on public.scheduled_events (status, resolves_at);
create index scheduled_events_asset_idx  on public.scheduled_events (asset_id);

alter table public.scheduled_events enable row level security;

-- Public calendar: readable by everyone, but only the non-outcome columns.
grant select (id, asset_id, kind, headline, quarter, scheduled_at, resolves_at, status)
  on public.scheduled_events to anon, authenticated;
create policy "calendar readable" on public.scheduled_events for select using (true);

-- Tuning.
insert into public.game_config (key, value, description) values
  ('earnings_schedule_probability', '0.03',
   'Per-tick chance of scheduling a new upcoming earnings event.'),
  ('earnings_max_pending', '5',
   'Max concurrent scheduled (unresolved) earnings events.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- Schedule an upcoming earnings announcement with a hidden outcome. Picks a
-- random open stock/company that has no earnings already pending.
-- ----------------------------------------------------------------------------
create or replace function game.schedule_earnings_event()
returns void
language plpgsql
as $$
declare
  v_asset     public.assets%rowtype;
  v_roll      numeric := random();
  v_sentiment text;
  v_impact    numeric;
  v_quarter   text := 'Q' || (1 + floor(random() * 4))::int;
  v_lead      int;
begin
  -- Respect the concurrency cap.
  if (select count(*) from public.scheduled_events where status = 'scheduled')
       >= game.config_numeric('earnings_max_pending')::int then
    return;
  end if;

  select a.* into v_asset from public.assets a
   where a.is_active and a.class_id in ('stocks', 'companies')
     and game.is_market_open(a.market_hours)
     and not exists (select 1 from public.scheduled_events se
                      where se.asset_id = a.id and se.status = 'scheduled')
   order by random() limit 1;
  if not found then return; end if;

  -- Hidden outcome: ~45% beat, ~40% miss, ~15% inline.
  if v_roll < 0.45 then
    v_sentiment := 'positive';
    v_impact := round((0.03 + random() * 0.09)::numeric, 4);
  elsif v_roll < 0.85 then
    v_sentiment := 'negative';
    v_impact := round((-0.12 + random() * 0.09)::numeric, 4);
  else
    v_sentiment := 'neutral';
    v_impact := round((-0.015 + random() * 0.03)::numeric, 4);
  end if;

  -- Countdown of 90s–5min so there's real time to position.
  v_lead := 90 + floor(random() * 210)::int;

  insert into public.scheduled_events
    (asset_id, kind, headline, quarter, resolves_at,
     sentiment, fv_impact, vol_multiplier, duration_seconds)
  values
    (v_asset.id, 'earnings',
     v_asset.name || ' (' || v_asset.symbol || ') reports ' || v_quarter || ' earnings',
     v_quarter, now() + make_interval(secs => v_lead),
     v_sentiment, v_impact, round((1.4 + random() * 0.8)::numeric, 4), 1200);
end;
$$;

-- ----------------------------------------------------------------------------
-- Resolve any due earnings whose market is open: emit a real market_event
-- (which the tick's step-2 then applies as a fair-value shock) and mark the
-- schedule resolved. Called at the top of the tick, before shocks are applied.
-- ----------------------------------------------------------------------------
create or replace function game.resolve_scheduled_events()
returns void
language plpgsql
as $$
declare
  v_se       record;
  v_headline text;
  v_body     text;
  v_event_id uuid;
begin
  for v_se in
    select se.*, a.name as asset_name, a.symbol as asset_symbol,
           a.sector as asset_sector, a.market_hours
      from public.scheduled_events se
      join public.assets a on a.id = se.asset_id
     where se.status = 'scheduled' and se.resolves_at <= now()
       and game.is_market_open(a.market_hours)
     order by se.resolves_at
     for update of se
  loop
    v_headline := case v_se.sentiment
      when 'positive' then v_se.asset_name || ' smashes ' || v_se.quarter || ' estimates'
      when 'negative' then v_se.asset_name || ' misses ' || v_se.quarter || ' estimates'
      else v_se.asset_name || ' meets ' || v_se.quarter || ' expectations'
    end;
    v_body := case v_se.sentiment
      when 'positive' then v_se.asset_symbol || ' beat expectations on both revenue and '
        || 'guidance — traders who bought the anticipation are being paid.'
      when 'negative' then v_se.asset_symbol || ' came in short of estimates and cut its '
        || 'outlook. The stock reprices lower on the miss.'
      else v_se.asset_symbol || ' landed roughly in line with expectations — a muted '
        || 'reaction as the report held few surprises.'
    end;

    insert into public.market_events
      (template_code, scope, asset_id, sector, headline, body, sentiment,
       fv_impact, vol_multiplier, starts_at, ends_at)
    values
      (null, 'asset', v_se.asset_id, v_se.asset_sector, v_headline, v_body,
       v_se.sentiment, v_se.fv_impact, v_se.vol_multiplier,
       now(), now() + make_interval(secs => v_se.duration_seconds))
    returning id into v_event_id;

    update public.scheduled_events
       set status = 'resolved', resolved_event_id = v_event_id
     where id = v_se.id;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Hook scheduling + resolution into the tick. Same body as migration 28, with
-- resolution first (so a resolved event's shock lands this same tick via step 2)
-- and a scheduling roll alongside the news spawn.
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

-- Live calendar updates (new announcements appear, resolved ones flip status).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.scheduled_events;
  end if;
end $$;
