-- ============================================================================
-- Migration 40: Passive income — dividends (stocks) + rent (real estate).
--
-- An accrue-and-claim idle loop. Holdings quietly earn income in game-time
-- while the player is away; a Collect action (surfaced by the "While you were
-- away" card) sweeps the pending balance into cash. Deliberately SLOW: yields
-- are modest and realized over a game-year (14 real days at the current
-- seconds_per_game_year), so wealth still takes real time to compound and the
-- game keeps its long horizon. Every rate lives in game_config / assets so it
-- can be tuned without a migration.
--
-- Design notes:
--   * Accrual is a periodic pg_cron job (game.accrue_income) — market_tick is
--     left untouched, matching how the predictive-loops work stayed out of it.
--   * last_accrued_at advances for EVERY player each run (not just holders), so
--     buying an income asset never retroactively pays for time you didn't hold.
--   * Income is in-game cash from owned assets — a new 'passive_income' ledger
--     type, positive-only, keeps the append-only monetization guarantee intact.
-- ============================================================================

-- 1. Config knobs ------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('income_enabled',     '1',    'Master switch for passive-income accrual (1 = on, 0 = off).'),
  ('income_min_collect', '0.01', 'Smallest pending amount collect_income() will pay out.')
on conflict (key) do nothing;

-- 2. Yield column on assets --------------------------------------------------
alter table public.assets
  add column income_yield numeric not null default 0
  check (income_yield >= 0 and income_yield < 1);
comment on column public.assets.income_yield is
  'Annual passive-income yield as a fraction of position value: dividends for '
  'stocks/companies, rent for real estate. 0 = pays nothing (e.g. growth tech).';

-- Expose it to clients (the assets grant is column-restricted) for the
-- projected-income tile.
grant select (income_yield) on public.assets to anon, authenticated;

-- 3. Seed the yields ---------------------------------------------------------
-- On a HOSTED DB the assets already exist, so these UPDATEs set real values.
-- On a from-scratch reset the assets table is still empty here (assets seed
-- AFTER migrations) so these no-op and seed.sql applies the same values — the
-- established seed-timing pattern (cf. livelier-markets base_volatility).
-- Mature, cash-generative sectors pay dividends; growth/tech reinvest (0).
update public.assets set income_yield = 0.030 where class_id = 'stocks' and symbol = 'SLCT';
update public.assets set income_yield = 0.050 where class_id = 'stocks' and symbol = 'XOFF'; -- "big dividends"
update public.assets set income_yield = 0.030 where class_id = 'stocks' and symbol in ('GMSX','GEKO');
update public.assets set income_yield = 0.020 where class_id = 'stocks' and symbol = 'VIZA';
update public.assets set income_yield = 0.035 where class_id = 'stocks' and symbol = 'KOKA';
update public.assets set income_yield = 0.020 where class_id = 'stocks' and symbol in ('SBRW','NIKY');
update public.assets set income_yield = 0.035 where class_id = 'stocks' and symbol = 'JNJN';
update public.assets set income_yield = 0.030 where class_id = 'stocks' and symbol = 'PFZR';
-- Real estate: every REIT earns rent, varying with property risk.
update public.assets set income_yield = 0.050 where symbol in ('DWTN','WRHS');
update public.assets set income_yield = 0.055 where symbol = 'SUBH';
update public.assets set income_yield = 0.045 where symbol = 'MALL';
update public.assets set income_yield = 0.065 where symbol = 'ISLE';

-- 4. Pending-income ledger per player ---------------------------------------
create table public.user_income (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  pending_dividends numeric(18,2) not null default 0 check (pending_dividends >= 0),
  pending_rent      numeric(18,2) not null default 0 check (pending_rent >= 0),
  lifetime_income   numeric(18,2) not null default 0 check (lifetime_income >= 0),
  last_accrued_at   timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
alter table public.user_income enable row level security;
create policy "own income readable" on public.user_income
  for select using (user_id = auth.uid());
grant select on public.user_income to authenticated;

-- Stream pending updates so the Portfolio card visibly ticks up.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_income;
  end if;
end $$;

-- 5. Row lifecycle: one per player, created on signup + backfilled -----------
create or replace function game.ensure_income_row()
returns trigger
language plpgsql
security definer
set search_path = public, game
as $$
begin
  insert into public.user_income (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger profiles_income_row
  after insert on public.profiles
  for each row execute function game.ensure_income_row();

insert into public.user_income (user_id)
  select id from public.profiles
  on conflict (user_id) do nothing;

-- 6. Accrual: credit each player's pending buckets for elapsed game-time -----
-- p_user null = accrue everyone (the cron path); a uuid = just that player
-- (called at collect time so a Collect always sweeps up-to-the-second income).
create or replace function game.accrue_income(p_user uuid default null)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_spy numeric := game.config_numeric('seconds_per_game_year');
begin
  if game.config_numeric('income_enabled') < 1 then return; end if;
  if v_spy is null or v_spy <= 0 then return; end if;

  update public.user_income ui
     set pending_dividends = ui.pending_dividends
           + round(calc.div_rate * calc.frac, 2),
         pending_rent = ui.pending_rent
           + round(calc.rent_rate * calc.frac, 2),
         last_accrued_at = now(),
         updated_at = now()
    from (
      select me.user_id,
             extract(epoch from now() - me.last_accrued_at) / v_spy as frac,
             coalesce(sum(case when a.class_id = 'real_estate'
                               then h.quantity * a.current_price * a.income_yield
                               else 0 end), 0) as rent_rate,
             coalesce(sum(case when a.class_id <> 'real_estate'
                               then h.quantity * a.current_price * a.income_yield
                               else 0 end), 0) as div_rate
        from public.user_income me
        left join public.holdings h on h.user_id = me.user_id and h.quantity > 0
        left join public.assets a on a.id = h.asset_id and a.income_yield > 0
       where p_user is null or me.user_id = p_user
       group by me.user_id, me.last_accrued_at
    ) calc
   where calc.user_id = ui.user_id;
end $$;

-- 7. Collect: sweep pending into cash via the append-only ledger -------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income'
  ));
alter table public.transactions add constraint transactions_passive_income_credits
  check (type <> 'passive_income' or (cash_delta > 0 and qty_delta = 0));

create or replace function public.collect_income()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_inc   public.user_income%rowtype;
  v_total numeric;
  v_min   numeric := coalesce(game.config_numeric('income_min_collect'), 0.01);
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  -- Fold in income accrued right up to this moment, then read + lock the row.
  perform game.accrue_income(v_user);
  select * into v_inc from public.user_income where user_id = v_user for update;

  if v_inc.user_id is null then
    return jsonb_build_object('status', 'empty',
                              'dividends', 0, 'rent', 0, 'total', 0);
  end if;

  v_total := v_inc.pending_dividends + v_inc.pending_rent;
  if v_total < v_min then
    return jsonb_build_object('status', 'empty',
                              'dividends', v_inc.pending_dividends,
                              'rent', v_inc.pending_rent, 'total', v_total);
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'passive_income', v_total, 'income');

  update public.user_income
     set pending_dividends = 0,
         pending_rent = 0,
         lifetime_income = lifetime_income + v_total,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'collected',
                            'dividends', v_inc.pending_dividends,
                            'rent', v_inc.pending_rent, 'total', v_total);
end $$;

grant execute on function public.collect_income() to authenticated;

-- 8. Schedule the accrual (every 2 minutes) ----------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'accrue-passive-income',
      '*/2 * * * *',
      $cron$ select game.accrue_income(); $cron$
    );
  else
    raise notice 'pg_cron missing: run game.accrue_income() externally.';
  end if;
end $$;
