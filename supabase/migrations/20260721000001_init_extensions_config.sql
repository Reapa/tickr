-- ============================================================================
-- Migration 1: extensions, game configuration, shared helpers
-- ============================================================================

-- gen_random_uuid() is built into Postgres 13+, pgcrypto adds digest() etc.
create extension if not exists pgcrypto;

-- pg_cron drives the market tick on hosted Supabase. It may be unavailable in
-- some local setups, so the actual cron.schedule() call (migration 8) is
-- guarded; enabling it here is best-effort too.
do $$
begin
  create extension if not exists pg_cron;
exception when others then
  raise notice 'pg_cron not available in this environment (%). Enable it in the Supabase dashboard, or drive ticks via the admin-tick edge function.', sqlerrm;
end $$;

-- All game logic lives in the "game" schema; public-facing RPCs live in
-- "public" so PostgREST exposes them.
create schema if not exists game;

-- ----------------------------------------------------------------------------
-- game_config: single source of truth for tunable knobs.
-- ----------------------------------------------------------------------------
create table public.game_config (
  key         text primary key,
  value       jsonb not null,
  description text not null,
  updated_at  timestamptz not null default now()
);

comment on table public.game_config is
  'Tunable simulation and economy knobs. Read-only to clients; changed by operators via SQL.';

insert into public.game_config (key, value, description) values
  ('tick_seconds',         '5',      'Seconds between market ticks. Must match the pg_cron schedule.'),
  ('seconds_per_game_year','604800', 'Wall-clock seconds representing one "year" of drift/volatility (default: 7 days).'),
  ('starting_cash',        '10000',  'Cash granted to every new player.'),
  ('starting_premium',     '200',    'Premium (cosmetic-only) currency granted to every new player.'),
  ('flow_halflife_seconds','60',     'Half-life of the net order-flow accumulator that drives price impact.'),
  ('event_spawn_probability','0.02', 'Per-tick probability that a news event spawns.'),
  ('max_order_notional',   '10000000', 'Hard cap on a single order''s notional value.'),
  ('price_tick_retention_days','7',  'Raw price ticks older than this are pruned each tick.'),
  ('season_length_days',   '14',     'Length of a competitive season.'),
  ('xp_per_trade',         '10',     'XP awarded per executed trade.');

create or replace function game.config_numeric(p_key text)
returns numeric
language sql
stable
as $$
  select (value #>> '{}')::numeric from public.game_config where key = p_key;
$$;

comment on function game.config_numeric is 'Read a numeric config knob.';

-- ----------------------------------------------------------------------------
-- Shared helpers
-- ----------------------------------------------------------------------------

-- Standard-normal draw via Box–Muller. 1 - random() keeps ln() away from 0.
create or replace function game.random_normal()
returns double precision
language sql
volatile
as $$
  select sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());
$$;

-- Human-friendly unique friend codes, e.g. "TG-7KQ2XN".
create or replace function game.generate_friend_code()
returns text
language sql
volatile
as $$
  select 'TG-' || upper(
    translate(
      substr(encode(gen_random_bytes(8), 'base64'), 1, 6),
      'O0Il+/=', 'ABCDEFG'  -- avoid ambiguous / non-alphanumeric characters
    )
  );
$$;

-- Append-only guard: attach as BEFORE UPDATE OR DELETE trigger to ledgers.
create or replace function game.forbid_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only; % is not allowed', tg_table_name, tg_op;
end;
$$;
