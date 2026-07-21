-- ============================================================================
-- Migration 2: asset classes, assets, price history, market events
-- ============================================================================

-- ----------------------------------------------------------------------------
-- asset_classes: the progression ladder. Players buy their way into new
-- classes with in-game cash (unlock_cost). "stocks" costs 0 and is granted at
-- signup; "companies" ships disabled as a scaffold for a future tier.
-- ----------------------------------------------------------------------------
create table public.asset_classes (
  id          text primary key,
  name        text not null,
  description text not null,
  unlock_cost numeric(18,2) not null check (unlock_cost >= 0),
  is_enabled  boolean not null default true,
  sort_order  int not null
);

comment on table public.asset_classes is
  'Progression tiers. unlock_cost is paid in in-game cash via purchase_asset_class_unlock().';

-- ----------------------------------------------------------------------------
-- assets: tradeable instruments. fair_value and the simulation parameters are
-- hidden from clients via column-level grants (migration 6); players only ever
-- see current_price and descriptive columns.
-- ----------------------------------------------------------------------------
create table public.assets (
  id              uuid primary key default gen_random_uuid(),
  symbol          text not null unique,
  name            text not null,
  class_id        text not null references public.asset_classes (id),
  sector          text not null,
  description     text not null default '',
  -- public price
  current_price   numeric(18,4) not null check (current_price > 0),
  -- hidden simulation state
  fair_value      numeric(18,4) not null check (fair_value > 0),
  flow            numeric(20,4) not null default 0,   -- decaying net player order flow (signed notional)
  -- hidden simulation parameters
  drift           numeric(8,4)  not null default 0.05,   -- annualized expected return
  base_volatility numeric(8,4)  not null default 0.30 check (base_volatility > 0), -- annualized sigma
  liquidity       numeric(20,4) not null default 500000 check (liquidity > 0),     -- notional scale of tanh impact
  impact_coef     numeric(8,4)  not null default 0.05 check (impact_coef >= 0),    -- max fractional price impact of flow
  reversion_speed numeric(8,4)  not null default 0.25 check (reversion_speed > 0 and reversion_speed <= 1),
  spread          numeric(8,5)  not null default 0.002 check (spread >= 0),        -- full spread; fills pay half
  is_active       boolean not null default true,
  listed_at       timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index assets_class_idx  on public.assets (class_id) where is_active;
create index assets_sector_idx on public.assets (sector);

comment on column public.assets.fair_value is
  'Hidden intrinsic value the traded price mean-reverts toward. Never exposed to clients.';
comment on column public.assets.flow is
  'Decaying accumulator of signed player order notional; drives price impact (net buying pushes price up).';

-- ----------------------------------------------------------------------------
-- price_ticks: public per-asset time series. Powers charts and is the
-- Realtime channel clients subscribe to for live prices.
-- ----------------------------------------------------------------------------
create table public.price_ticks (
  id       bigint generated always as identity primary key,
  asset_id uuid not null references public.assets (id) on delete cascade,
  price    numeric(18,4) not null,
  tick_at  timestamptz not null default now()
);

create index price_ticks_asset_time_idx on public.price_ticks (asset_id, tick_at desc);
create index price_ticks_time_idx on public.price_ticks (tick_at);

-- ----------------------------------------------------------------------------
-- event_templates: the generator library for news events. market_tick() rolls
-- against event_spawn_probability, picks a template by weight, targets a
-- random asset/sector, and instantiates a market_event from it.
-- ----------------------------------------------------------------------------
create table public.event_templates (
  id                bigint generated always as identity primary key,
  code              text not null unique,
  scope             text not null check (scope in ('asset', 'sector', 'market')),
  headline_template text not null,   -- {name}/{symbol}/{sector} placeholders
  body_template     text not null,
  fv_impact_min     numeric(8,4) not null,  -- one-time fair-value shock, fraction (e.g. -0.12)
  fv_impact_max     numeric(8,4) not null,
  vol_multiplier    numeric(8,4) not null default 1 check (vol_multiplier >= 1),
  duration_seconds  int not null check (duration_seconds > 0),
  weight            numeric(8,4) not null default 1 check (weight > 0),
  class_id          text references public.asset_classes (id),  -- null = any class
  check (fv_impact_min <= fv_impact_max)
);

-- ----------------------------------------------------------------------------
-- market_events: instantiated events — the in-game news feed. The fair-value
-- shock is applied exactly once (applied flag); vol_multiplier stays in force
-- until ends_at. fv_impact/vol_multiplier are hidden columns so players must
-- judge severity from the headline, not read the answer key.
-- ----------------------------------------------------------------------------
create table public.market_events (
  id             uuid primary key default gen_random_uuid(),
  template_code  text references public.event_templates (code),
  scope          text not null check (scope in ('asset', 'sector', 'market')),
  asset_id       uuid references public.assets (id) on delete cascade,
  sector         text,
  headline       text not null,
  body           text not null,
  sentiment      text not null check (sentiment in ('positive', 'negative', 'neutral')),
  fv_impact      numeric(8,4) not null,
  vol_multiplier numeric(8,4) not null default 1,
  starts_at      timestamptz not null default now(),
  ends_at        timestamptz not null,
  applied        boolean not null default false,
  check (ends_at > starts_at),
  check (scope <> 'asset'  or asset_id is not null),
  check (scope <> 'sector' or sector is not null)
);

create index market_events_active_idx on public.market_events (ends_at) where not applied;
create index market_events_feed_idx   on public.market_events (starts_at desc);
create index market_events_asset_idx  on public.market_events (asset_id, starts_at desc);
