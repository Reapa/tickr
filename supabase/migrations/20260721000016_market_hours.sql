-- ============================================================================
-- Migration 16: market trading hours + the 24/7 asset universe
--
-- Real-market rhythm: stocks and real estate trade weekdays 06:00-22:00 UTC;
-- forex trades 24/5 (closed Fri 22:00 UTC -> Sun 22:00 UTC); crypto never
-- sleeps. Closed markets freeze: no drift, no ticks, no fills, no triggers,
-- no liquidations — positions are simply frozen until the market reopens.
-- Weekends belong to crypto and the brave.
--
-- game_config.markets_always_open = true overrides everything (dev + tests).
-- ============================================================================

alter table public.assets add column market_hours text not null default 'weekday_day'
  check (market_hours in ('24_7', '24_5', 'weekday_day'));

grant select (market_hours) on public.assets to anon, authenticated;

insert into public.game_config (key, value, description) values
  ('markets_always_open', 'false',
   'Dev/test override: when true every market ignores trading hours.')
on conflict (key) do nothing;

create or replace function game.is_market_open(
  p_hours text,
  p_at    timestamptz default now()
)
returns boolean
language sql
stable
as $$
  with t as (
    select extract(isodow from p_at at time zone 'utc') as dow,   -- 1=Mon..7=Sun
           extract(hour   from p_at at time zone 'utc') as hr
  )
  select case
    when (select (value #>> '{}')::boolean from public.game_config
           where key = 'markets_always_open') then true
    when p_hours = '24_7' then true
    when p_hours = '24_5' then not exists (
      select 1 from t
       where dow = 6                      -- all Saturday
          or (dow = 5 and hr >= 22)       -- Friday night
          or (dow = 7 and hr < 22))       -- most of Sunday
    when p_hours = 'weekday_day' then exists (
      select 1 from t where dow between 1 and 5 and hr >= 6 and hr < 22)
    else true
  end;
$$;
