-- ============================================================================
-- Migration 36: keep price history from eating the disk
--
-- Raw ticks are the whole database: on 2026-07-30 price_ticks was 433 MB and
-- net_worth_history 126 MB out of a 603 MB total, which pushed the project past
-- its storage quota. Once over, the instance starved for IO badly enough that
-- PostgREST's schema-cache bootstrap (a plain `select from pg_timezone_names`)
-- could not finish inside the 2-minute statement timeout, so every REST request
-- returned PGRST002 and the app went dark while the market itself kept ticking.
--
-- Two causes, both fixed here:
--
-- 1. Retention had drifted. Migration 1 seeds price_tick_retention_days = 7,
--    but production was running 14 — changed by hand against the hosted DB, so
--    nothing in the repo recorded it and every redeploy left it in place. The
--    value is re-asserted below; game_config is operator-tunable, so this only
--    resets the knob rather than locking it.
--
-- 2. Deleting only at the retention edge keeps every 5-second sample at full
--    resolution for the entire window. The charts never need that: the finest
--    bucket the UI offers is 1m (price_chart.dart) and the net-worth series
--    buckets a 7-day window into 300 points (~34m each). Sampling that is
--    finer than anything ever drawn is pure storage cost.
--
-- So history is now compacted as it ages instead of only being truncated:
-- recent data stays at full tick resolution, older data keeps one sample per
-- chart-visible interval. Chart depth is unchanged; only intra-bucket high/low
-- detail on old candles is lost, which no view renders.
-- ============================================================================

insert into public.game_config (key, value, description) values
  ('price_tick_retention_days', '7',
   'Raw price ticks older than this are pruned. Compaction (below) thins them well before this edge.'),
  ('price_tick_fullres_days',   '3',
   'Ticks younger than this keep full 5s resolution; older ticks thin to one sample per asset per minute.'),
  ('net_worth_fullres_days',    '2',
   'Net-worth snapshots younger than this keep full resolution; older ones thin to one sample per user per 15 minutes.')
on conflict (key) do update
  set value = excluded.value, description = excluded.description;

-- ----------------------------------------------------------------------------
-- Compaction. Chunked one day at a time and capped per run: an unbounded pass
-- sorts the whole table, which on a starved instance overruns the statement
-- timeout and holds row locks against the 5s tick. Each run does bounded work
-- and the schedule catches up.
-- ----------------------------------------------------------------------------
create or replace function game.compact_price_history()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_tick_cut timestamptz := now() - make_interval(days => coalesce(game.config_numeric('price_tick_fullres_days'), 3)::int);
  v_nw_cut   timestamptz := now() - make_interval(days => coalesce(game.config_numeric('net_worth_fullres_days'), 2)::int);
  v_day      timestamptz;
  v_lo       timestamptz;
begin
  -- price_ticks: one sample per asset per minute once past the full-res window.
  select date_trunc('day', min(tick_at)) into v_lo from public.price_ticks;
  v_day := v_lo;
  while v_day is not null and v_day < date_trunc('day', v_tick_cut) loop
    delete from public.price_ticks
     where id in (
       select id from (
         select id,
                row_number() over (
                  partition by asset_id, date_trunc('minute', tick_at)
                  order by tick_at
                ) as rn
           from public.price_ticks
          where tick_at >= v_day and tick_at < v_day + interval '1 day'
       ) ranked
       where rn > 1
     );
    v_day := v_day + interval '1 day';
  end loop;

  -- net_worth_history: one sample per user per 15 minutes once past its window.
  select date_trunc('day', min(tick_at)) into v_lo from public.net_worth_history;
  v_day := v_lo;
  while v_day is not null and v_day < date_trunc('day', v_nw_cut) loop
    delete from public.net_worth_history
     where id in (
       select id from (
         select id,
                row_number() over (
                  partition by user_id, div(extract(epoch from tick_at)::bigint, 900)
                  order by tick_at
                ) as rn
           from public.net_worth_history
          where tick_at >= v_day and tick_at < v_day + interval '1 day'
       ) ranked
       where rn > 1
     );
    v_day := v_day + interval '1 day';
  end loop;
end $$;

comment on function game.compact_price_history() is
  'Thins aged price/net-worth history down to the finest resolution any chart '
  'actually draws (1 minute for ticks, 15 minutes for net worth). Runs hourly; '
  'retention pruning still trims the far edge.';

-- ----------------------------------------------------------------------------
-- Schedule. Hourly is well inside the daily boundaries compaction works on, so
-- a missed run costs nothing and the next one catches up. Guarded the same way
-- as the other cron registrations so environments without pg_cron still migrate.
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('compact-price-history')
      where exists (select 1 from cron.job where jobname = 'compact-price-history');
    perform cron.schedule('compact-price-history', '17 * * * *',
      $cron$select game.compact_price_history();$cron$);
  end if;
end $$;
