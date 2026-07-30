-- ============================================================================
-- Migration 37: storage budget guard
--
-- Migration 36 stops history growing without bound, which fixes the cause of
-- the 2026-07-30 outage. This adds the backstop: something that notices the
-- database trending toward its quota *before* it gets there, records the trend
-- so it can be looked at, and tightens compaction on its own if nobody does.
--
-- The outage was not caused by a sudden spike. Storage crept up over eight days
-- and the first signal anyone got was the app going dark — by which point the
-- instance was too starved to serve the API that would have shown the problem.
-- A guard is only useful if it acts before that point, so this one both alerts
-- and remediates.
-- ============================================================================

insert into public.game_config (key, value, description) values
  ('storage_budget_bytes', '536870912',
   'Storage ceiling to plan against, in bytes (free tier = 0.5 GiB). Raise this after a plan upgrade.'),
  ('storage_soft_pct',     '0.70',
   'Fraction of the budget above which compaction runs early and a warning is recorded.'),
  ('storage_hard_pct',     '0.85',
   'Fraction of the budget above which compaction also shortens the full-resolution window.')
on conflict (key) do update
  set value = excluded.value, description = excluded.description;

-- ----------------------------------------------------------------------------
-- Trend log. Small and self-pruning: this table must never become the thing it
-- exists to prevent.
-- ----------------------------------------------------------------------------
create table if not exists public.storage_health (
  id         bigint generated always as identity primary key,
  checked_at timestamptz not null default now(),
  db_bytes   bigint      not null,
  pct_used   numeric(5,4) not null,
  status     text        not null check (status in ('ok', 'warn', 'critical')),
  note       text
);

create index if not exists storage_health_time_idx
  on public.storage_health (checked_at desc);

alter table public.storage_health enable row level security;

comment on table public.storage_health is
  'Storage-usage samples taken every 15 minutes. Trend data for spotting growth '
  'before it hits the quota; 30-day rolling window.';

-- ----------------------------------------------------------------------------
-- The guard itself.
--
-- Escalation deliberately stops at "compact harder". Above the hard threshold
-- it shortens the full-resolution window for that run only, which drops sub-
-- minute detail on recent ticks but leaves every chart bucket the UI can draw
-- (finest is 1m) fully intact. It does NOT touch the retention edge on its own:
-- shortening retention destroys history a player can see, and that should stay
-- a human decision rather than something a cron job does at 3am.
-- ----------------------------------------------------------------------------
create or replace function game.enforce_storage_budget()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_bytes  bigint  := pg_database_size(current_database());
  v_budget numeric := coalesce(game.config_numeric('storage_budget_bytes'), 536870912);
  v_soft   numeric := coalesce(game.config_numeric('storage_soft_pct'), 0.70);
  v_hard   numeric := coalesce(game.config_numeric('storage_hard_pct'), 0.85);
  v_pct    numeric := v_bytes / nullif(v_budget, 0);
  v_status text    := 'ok';
  v_note   text    := null;
  v_prev   numeric;
begin
  if v_pct >= v_hard then
    v_status := 'critical';

    -- Temporarily tighten the full-res window, compact, then restore it. The
    -- restore is in the same statement flow rather than a later run, so a
    -- failure here cannot leave the game permanently sampling less than the
    -- operator configured.
    select value::numeric into v_prev from public.game_config
      where key = 'price_tick_fullres_days';

    update public.game_config set value = '1' where key = 'price_tick_fullres_days';
    perform game.compact_price_history();
    update public.game_config set value = coalesce(v_prev, 3)::text
      where key = 'price_tick_fullres_days';

    v_note := format('at %s%% of budget: compacted with a 1-day full-res window (normally %s)',
                     round(v_pct * 100, 1), coalesce(v_prev, 3));

  elsif v_pct >= v_soft then
    v_status := 'warn';
    perform game.compact_price_history();
    v_note := format('at %s%% of budget: ran compaction early', round(v_pct * 100, 1));
  end if;

  insert into public.storage_health (db_bytes, pct_used, status, note)
  values (v_bytes, least(v_pct, 9.9999), v_status, v_note);

  delete from public.storage_health where checked_at < now() - interval '30 days';
end $$;

comment on function game.enforce_storage_budget() is
  'Samples database size every 15 minutes into storage_health, and compacts '
  'history early (soft threshold) or with a shortened full-resolution window '
  '(hard threshold). Never shortens retention on its own.';

-- ----------------------------------------------------------------------------
-- A read-only view of the trend, so storage can be checked from the app or a
-- REST call without a psql session — the thing that was impossible mid-outage.
-- ----------------------------------------------------------------------------
create or replace function public.get_storage_health(p_limit int default 96)
returns table (checked_at timestamptz, db_bytes bigint, pct_used numeric, status text, note text)
language sql
stable
security definer
set search_path = public
as $$
  select checked_at, db_bytes, pct_used, status, note
    from public.storage_health
   order by checked_at desc
   limit least(greatest(coalesce(p_limit, 96), 1), 1000);
$$;

revoke all on function public.get_storage_health(int) from public, anon;
grant execute on function public.get_storage_health(int) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('enforce-storage-budget')
      where exists (select 1 from cron.job where jobname = 'enforce-storage-budget');
    perform cron.schedule('enforce-storage-budget', '*/15 * * * *',
      $cron$select game.enforce_storage_budget();$cron$);
  end if;
end $$;
