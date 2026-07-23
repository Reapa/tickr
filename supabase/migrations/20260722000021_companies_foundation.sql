-- ============================================================================
-- Migration 41: Companies tycoon tier — Phase 1 "Own a business".
--
-- Activates the long-disabled `companies` class ($250k gate) as a second,
-- ownership-and-cashflow pillar beside trading. This phase: found your own
-- company (name + industry + startup capital) or buy an established one, earn
-- business revenue into the unified Collect loop, and see it in your net worth
-- and milestones — WITHOUT it distorting the competitive seasons.
--
-- The balance crux — a SEPARATE WEALTH TRACK:
--   trading_net_worth = cash + marked holdings + leverage equity  (drives seasons)
--   business_equity   = owned-company value (+ founder shares once public)
--   net_worth         = trading_net_worth + business_equity        (total; shown
--                       to the player, drives milestones + the net-worth chart)
-- Seasons (game.update_season_scores) switch to trading_net_worth, so a tycoon
-- empire grows your wealth and milestones but never inflates your season rank.
-- Consequence (intended): capital you commit to a company leaves your trading
-- balance, so it stops counting toward the current season — companies are a
-- long-game wealth play, not a season play.
--
-- Later phases: P2 decisions/management, P3 property events, P4 IPO. The schema
-- here already carries the P2/P4 columns (stats, status, founder_shares) so the
-- foundation doesn't need reshaping.
-- ============================================================================

-- 0. Config knobs ------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('companies_enabled',      '1',  'Master switch for the companies tycoon tier.'),
  ('company_sell_haircut',   '0.10','Fraction lost when selling a company back for cash.'),
  ('company_listings_target','6',  'How many buy-existing listings to keep available.')
on conflict (key) do nothing;

-- 1. Enable the class (was a disabled scaffold) ------------------------------
update public.asset_classes set is_enabled = true where id = 'companies';

-- 2. Net-worth split columns -------------------------------------------------
alter table public.profiles
  add column trading_net_worth numeric(18,2) not null default 0,
  add column business_equity   numeric(18,2) not null default 0;
-- Backfill so season scoring has a trading figure immediately (no companies yet,
-- so trading == current net worth).
update public.profiles set trading_net_worth = net_worth;
comment on column public.profiles.trading_net_worth is
  'Cash + holdings + leverage. Drives season %% return (business equity excluded).';
comment on column public.profiles.business_equity is
  'Owned-company value + retained founder shares. In total net_worth, not seasons.';

-- 3. Ledger types for company capital flows ----------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income',
    'company_invest', 'company_sale'
  ));
alter table public.transactions add constraint transactions_company_invest_debits
  check (type <> 'company_invest' or (cash_delta < 0 and qty_delta = 0));
alter table public.transactions add constraint transactions_company_sale_credits
  check (type <> 'company_sale' or (cash_delta > 0 and qty_delta = 0));

-- 4. Catalogs ----------------------------------------------------------------
-- Industries you can found in. revenue_multiple sets valuation = revenue_rate *
-- multiple; initial revenue_rate = capital / multiple so a fresh company is
-- worth what you put in and earns capital/multiple per game-year (deliberately
-- modest — growth is the upside, via P2 decisions).
create table public.company_industries (
  id              text primary key,
  name            text not null,
  description     text not null,
  min_capital     numeric(18,2) not null,
  revenue_multiple numeric not null check (revenue_multiple > 0),
  risk            numeric not null default 0.5,
  income_yield    numeric not null default 0.03,  -- post-IPO dividend policy
  sort_order      int not null default 0
);

insert into public.company_industries
  (id, name, description, min_capital, revenue_multiple, risk, income_yield, sort_order) values
  ('software',  'Software',    'High-margin, fast-scaling, fickle. Big ceiling.',        50000,  22, 0.75, 0.010, 1),
  ('retail',    'Retail',      'Steady footfall, thin margins, needs constant marketing.',60000, 14, 0.45, 0.045, 2),
  ('energy',    'Energy',      'Capital-heavy and cyclical, but durable cash flows.',    120000,  16, 0.55, 0.050, 3),
  ('food',      'Food & Bev',  'Beloved brands compound slowly; fads fade fast.',         45000,  15, 0.50, 0.035, 4),
  ('logistics', 'Logistics',   'Boring, essential, expands well with reinvestment.',       80000,  17, 0.40, 0.040, 5),
  ('media',     'Media',       'Hit-driven: high variance, marketing-led growth.',         40000,  18, 0.80, 0.020, 6);

-- Fictional name pool for the "dynamic list" when founding. Players may also type
-- their own; found_company enforces per-player uniqueness.
create table public.company_name_pool (
  name text primary key
);
insert into public.company_name_pool (name) values
  ('Nimbus'),('Vertex Labs'),('Ironwood'),('Brightforge'),('Cobalt & Co'),
  ('Meridian'),('Northwind'),('Palisade'),('Quill'),('Redshift'),
  ('Sable'),('Tessellate'),('Umbra'),('Vantage'),('Wren'),('Zephyr'),
  ('Aster'),('Bramble'),('Cinder'),('Dovetail'),('Ember'),('Fathom'),
  ('Gravel & Grain'),('Halcyon'),('Indigo'),('Juniper'),('Kestrel'),('Lumen'),
  ('Marrow'),('Onyx'),('Pinnacle'),('Quarry'),('Rivet'),('Solstice'),
  ('Thistle'),('Ursa'),('Verdant'),('Wildcard'),('Yonder'),('Zenith');

-- Buy-existing catalog. Unique instances, consumed on purchase, topped up by
-- game.refresh_company_listings(). Established → steadier, pricier, lower ceiling.
create table public.company_listings (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  industry_id  text not null references public.company_industries (id),
  valuation    numeric(18,2) not null,
  revenue_rate numeric(18,2) not null,
  level        int not null default 3,
  available    boolean not null default true,
  created_at   timestamptz not null default now()
);
grant select on public.company_industries, public.company_name_pool,
                public.company_listings to anon, authenticated;

-- 5. Owned companies ---------------------------------------------------------
create table public.user_companies (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  name            text not null,
  industry_id     text not null references public.company_industries (id),
  origin          text not null check (origin in ('founded','acquired')),
  level           int not null default 1,
  revenue_rate    numeric(18,2) not null default 0,   -- cash per game-year
  valuation       numeric(18,2) not null default 0,
  invested_basis  numeric(18,2) not null default 0,
  brand           numeric not null default 0,          -- P2 decision levers
  rnd             numeric not null default 0,
  momentum        numeric not null default 0,
  status          text not null default 'private' check (status in ('private','public','sold')),
  public_asset_id uuid references public.assets (id),  -- set at IPO (P4)
  founder_shares  numeric(18,4) not null default 0,
  next_decision_at timestamptz,                        -- P2
  founded_at      timestamptz not null default now(),
  unique (user_id, name)
);
create index user_companies_user_idx on public.user_companies (user_id) where status <> 'sold';
alter table public.user_companies enable row level security;
create policy "own companies readable" on public.user_companies
  for select using (user_id = auth.uid());
grant select on public.user_companies to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_companies;
  end if;
end $$;

-- 6. Business income joins the unified Collect bucket ------------------------
alter table public.user_income
  add column pending_business numeric(18,2) not null default 0
  check (pending_business >= 0);

-- Extend accrual: private companies drip revenue_rate into pending_business,
-- prorated by game-time exactly like dividends/rent.
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
     set pending_dividends = ui.pending_dividends + round(calc.div_rate  * calc.frac, 2),
         pending_rent      = ui.pending_rent      + round(calc.rent_rate * calc.frac, 2),
         pending_business  = ui.pending_business  + round(calc.biz_rate  * calc.frac, 2),
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
                               else 0 end), 0) as div_rate,
             coalesce((select sum(uc.revenue_rate) from public.user_companies uc
                        where uc.user_id = me.user_id and uc.status = 'private'), 0) as biz_rate
        from public.user_income me
        left join public.holdings h on h.user_id = me.user_id and h.quantity > 0
        left join public.assets a on a.id = h.asset_id and a.income_yield > 0
       where p_user is null or me.user_id = p_user
       group by me.user_id, me.last_accrued_at
    ) calc
   where calc.user_id = ui.user_id;
end $$;

-- collect_income sweeps business income too.
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

  perform game.accrue_income(v_user);
  select * into v_inc from public.user_income where user_id = v_user for update;

  if v_inc.user_id is null then
    return jsonb_build_object('status', 'empty',
                              'dividends', 0, 'rent', 0, 'business', 0, 'total', 0);
  end if;

  v_total := v_inc.pending_dividends + v_inc.pending_rent + v_inc.pending_business;
  if v_total < v_min then
    return jsonb_build_object('status', 'empty',
                              'dividends', v_inc.pending_dividends,
                              'rent', v_inc.pending_rent,
                              'business', v_inc.pending_business, 'total', v_total);
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'passive_income', v_total, 'income');

  update public.user_income
     set pending_dividends = 0, pending_rent = 0, pending_business = 0,
         lifetime_income = lifetime_income + v_total,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('status', 'collected',
                            'dividends', v_inc.pending_dividends,
                            'rent', v_inc.pending_rent,
                            'business', v_inc.pending_business, 'total', v_total);
end $$;

-- 7. Found / buy / sell ------------------------------------------------------
create or replace function public.found_company(
  p_name text, p_industry text, p_capital numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_ind  public.company_industries%rowtype;
  v_name text := btrim(coalesce(p_name, ''));
  v_rate numeric;
  v_id   uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.user_asset_class_unlocks
                  where user_id = v_user and class_id = 'companies') then
    return jsonb_build_object('status','locked');
  end if;
  select * into v_ind from public.company_industries where id = p_industry;
  if not found then return jsonb_build_object('status','bad_industry'); end if;
  if v_name = '' then return jsonb_build_object('status','bad_name'); end if;
  if p_capital < v_ind.min_capital then
    return jsonb_build_object('status','under_min','min', v_ind.min_capital);
  end if;
  if exists (select 1 from public.user_companies
              where user_id = v_user and lower(name) = lower(v_name) and status <> 'sold') then
    return jsonb_build_object('status','name_taken');
  end if;
  if (select cash_balance from public.profiles where id = v_user) < p_capital then
    return jsonb_build_object('status','insufficient_cash');
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'company_invest', -p_capital, 'company');

  v_rate := round(p_capital / v_ind.revenue_multiple, 2);
  insert into public.user_companies
    (user_id, name, industry_id, origin, revenue_rate, valuation, invested_basis,
     next_decision_at)
  values (v_user, v_name, p_industry, 'founded', v_rate, p_capital, p_capital,
          now() + interval '2 hours')
  returning id into v_id;

  return jsonb_build_object('status','founded','company_id', v_id,
                            'name', v_name, 'revenue_rate', v_rate);
end $$;

create or replace function public.buy_company(p_listing uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_l    public.company_listings%rowtype;
  v_id   uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.user_asset_class_unlocks
                  where user_id = v_user and class_id = 'companies') then
    return jsonb_build_object('status','locked');
  end if;
  select * into v_l from public.company_listings where id = p_listing and available for update;
  if not found then return jsonb_build_object('status','unavailable'); end if;
  if exists (select 1 from public.user_companies
              where user_id = v_user and lower(name) = lower(v_l.name) and status <> 'sold') then
    return jsonb_build_object('status','name_taken');
  end if;
  if (select cash_balance from public.profiles where id = v_user) < v_l.valuation then
    return jsonb_build_object('status','insufficient_cash');
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'company_invest', -v_l.valuation, 'company', v_l.id::text);

  insert into public.user_companies
    (user_id, name, industry_id, origin, level, revenue_rate, valuation,
     invested_basis, next_decision_at)
  values (v_user, v_l.name, v_l.industry_id, 'acquired', v_l.level, v_l.revenue_rate,
          v_l.valuation, v_l.valuation, now() + interval '2 hours')
  returning id into v_id;

  update public.company_listings set available = false where id = v_l.id;
  perform game.refresh_company_listings();

  return jsonb_build_object('status','bought','company_id', v_id, 'name', v_l.name);
end $$;

create or replace function public.sell_company(p_company uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_c    public.user_companies%rowtype;
  v_haircut numeric := coalesce(game.config_numeric('company_sell_haircut'), 0.10);
  v_proceeds numeric;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_c from public.user_companies
   where id = p_company and user_id = v_user and status = 'private' for update;
  if not found then return jsonb_build_object('status','not_sellable'); end if;

  v_proceeds := round(v_c.valuation * (1 - v_haircut), 2);
  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'company_sale', v_proceeds, 'company', v_c.id::text);

  update public.user_companies set status = 'sold', revenue_rate = 0 where id = v_c.id;
  return jsonb_build_object('status','sold','proceeds', v_proceeds);
end $$;

grant execute on function public.found_company(text, text, numeric) to authenticated;
grant execute on function public.buy_company(uuid) to authenticated;
grant execute on function public.sell_company(uuid) to authenticated;

-- 8. Listings generator ------------------------------------------------------
create or replace function game.refresh_company_listings()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_target int := coalesce(game.config_numeric('company_listings_target'), 6)::int;
  v_have   int;
  v_ind    public.company_industries%rowtype;
  v_name   text;
  v_val    numeric;
  v_rate   numeric;
begin
  select count(*) into v_have from public.company_listings where available;
  while v_have < v_target loop
    select * into v_ind from public.company_industries order by random() limit 1;
    -- A name not currently listed or owned by anyone.
    select n.name into v_name from public.company_name_pool n
     where not exists (select 1 from public.company_listings l where l.available and l.name = n.name)
       and not exists (select 1 from public.user_companies c where c.name = n.name and c.status <> 'sold')
     order by random() limit 1;
    exit when v_name is null;  -- pool exhausted
    -- Established: comfortably above the industry minimum, steadier.
    v_val  := round((v_ind.min_capital * (2 + random() * 4))::numeric, 2);
    v_rate := round(v_val / v_ind.revenue_multiple, 2);
    insert into public.company_listings (name, industry_id, valuation, revenue_rate, level)
    values (v_name, v_ind.id, v_val, v_rate, 3 + floor(random() * 3)::int);
    v_have := v_have + 1;
  end loop;
end $$;

select game.refresh_company_listings();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('refresh-company-listings', '*/30 * * * *',
      $cron$ select game.refresh_company_listings(); $cron$);
  end if;
end $$;

-- 9. Net-worth split: redefine market_tick step 5 + season scoring -----------
-- Full redefine (unchanged from migration 20260722000014 except step 5, which
-- now computes trading_net_worth + business_equity + total net_worth).
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
             adv2.new_fair * (1 + adv2.impact_coef * tanh(adv2.new_flow / adv2.liquidity))
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

  -- 5. Refresh net worth. SPLIT: trading (cash + holdings + leverage) drives
  --    seasons; business (owned companies + retained founder shares) is added
  --    for the total shown to the player and used by milestones.
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
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0) as business
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

-- Seasons rank on trading net worth only.
create or replace function game.update_season_scores()
returns void
language plpgsql
as $$
declare
  v_season public.seasons%rowtype;
begin
  select * into v_season from public.seasons
   where status = 'active' and now() between starts_at and ends_at
   order by number desc limit 1;
  if not found then return; end if;

  insert into public.season_scores (season_id, user_id, starting_net_worth, current_net_worth)
  select v_season.id, p.id, greatest(p.trading_net_worth, 1), p.trading_net_worth
    from public.profiles p
   where not exists (select 1 from public.season_scores s
                      where s.season_id = v_season.id and s.user_id = p.id);

  update public.season_scores s
     set current_net_worth = p.trading_net_worth,
         pct_return = round(p.trading_net_worth / nullif(s.starting_net_worth, 0) - 1, 6)
    from public.profiles p
   where p.id = s.user_id and s.season_id = v_season.id;
end;
$$;
