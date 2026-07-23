-- ============================================================================
-- Migration 44: Property ownership — Phase 3a "Own real estate".
--
-- Until now real estate meant REIT *shares* you trade. This lets players buy
-- specific properties outright — a house, an office block, a resort — that earn
-- rent and build wealth, mirroring the Companies tycoon tier. Property value
-- sits on the SAME separate wealth track as companies: it counts toward total
-- net worth and milestones, but is excluded from season % return.
--
-- Gated behind the existing real-estate class unlock ($50k). REIT trading is
-- unchanged. Phase 3b adds growth decisions + maintenance events (repair/defer/
-- insurance); the condition/insured/next_*_at columns are carried here so that
-- phase needs no reshaping.
-- ============================================================================

-- 1. Config ------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('property_sell_haircut',    '0.05', 'Fraction lost when selling a property back for cash.'),
  ('property_listings_target', '6',    'How many properties to keep available to buy.')
on conflict (key) do nothing;

-- 2. Ledger types ------------------------------------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income',
    'company_invest', 'company_sale', 'property_invest', 'property_sale'
  ));
alter table public.transactions add constraint transactions_property_invest_debits
  check (type <> 'property_invest' or (cash_delta < 0 and qty_delta = 0));
alter table public.transactions add constraint transactions_property_sale_credits
  check (type <> 'property_sale' or (cash_delta > 0 and qty_delta = 0));

-- 3. Catalog -----------------------------------------------------------------
create table public.property_types (
  id           text primary key,
  name         text not null,
  description  text not null,
  min_price    numeric(18,2) not null,
  rent_yield   numeric not null check (rent_yield > 0),  -- annual rent / value
  risk         numeric not null default 0.5,
  sort_order   int not null default 0
);
insert into public.property_types
  (id, name, description, min_price, rent_yield, risk, sort_order) values
  ('residential', 'Residential', 'Homes and apartments — steady tenants, low drama.',   30000, 0.050, 0.30, 1),
  ('retail',      'Retail',      'Shops and high-street units — footfall pays the rent.', 50000, 0.055, 0.50, 2),
  ('commercial',  'Commercial',  'Offices and towers — big leases, big upkeep.',          80000, 0.060, 0.55, 3),
  ('industrial',  'Industrial',  'Warehouses and depots — boring, dependable yield.',     60000, 0.055, 0.35, 4),
  ('hospitality', 'Hospitality', 'Hotels and resorts — high yield, storm-exposed.',      100000, 0.070, 0.75, 5);

create table public.property_name_pool (name text primary key);
insert into public.property_name_pool (name) values
  ('Maple Court Apartments'),('Riverside Lofts'),('The Old Mill'),('Harbourgate Offices'),
  ('Sunset Villas'),('Ironbridge Warehouse'),('Kingsway Tower'),('Willow Park Homes'),
  ('The Arcade'),('Dockside Depot'),('Beacon Hill Resort'),('Cedar Row'),
  ('Grand Central Retail'),('Fairhaven Flats'),('Northgate Logistics'),('Palm Cove Hotel'),
  ('Brickworks Studios'),('Meadowbrook Estate'),('The Exchange'),('Seaview Terrace'),
  ('Highpoint Plaza'),('Amber Court'),('Quayside Units'),('Stonewall Offices'),
  ('Lakeshore Cabins'),('Union Square Shops'),('Foundry Lofts'),('Birchwood Homes'),
  ('Summit Business Park'),('Coral Bay Resort');

create table public.property_listings (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  type_id    text not null references public.property_types (id),
  value      numeric(18,2) not null,
  rent_rate  numeric(18,2) not null,
  available  boolean not null default true,
  created_at timestamptz not null default now()
);
grant select on public.property_types, public.property_name_pool,
                public.property_listings to anon, authenticated;

-- 4. Owned properties --------------------------------------------------------
create table public.user_properties (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  name           text not null,
  type_id        text not null references public.property_types (id),
  value          numeric(18,2) not null default 0,
  rent_rate      numeric(18,2) not null default 0,   -- cash per game-year at full condition
  invested_basis numeric(18,2) not null default 0,
  condition      numeric not null default 100 check (condition between 0 and 100),
  insured        boolean not null default false,
  status         text not null default 'owned' check (status in ('owned','sold')),
  next_decision_at timestamptz,                       -- P3b
  next_event_at    timestamptz,                       -- P3b
  bought_at      timestamptz not null default now()
);
create index user_properties_user_idx on public.user_properties (user_id) where status = 'owned';
alter table public.user_properties enable row level security;
create policy "own properties readable" on public.user_properties
  for select using (user_id = auth.uid());
grant select on public.user_properties to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_properties;
  end if;
end $$;

-- 5. Rent accrual: owned-property rent joins the pending_rent bucket ----------
-- Rent scales with condition (damaged property earns less — P3b). Full at 100.
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
                               else 0 end), 0)
             + coalesce((select sum(pr.rent_rate * pr.condition / 100.0)
                           from public.user_properties pr
                          where pr.user_id = me.user_id and pr.status = 'owned'), 0) as rent_rate,
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

-- 6. Buy / sell --------------------------------------------------------------
create or replace function public.buy_property(p_listing uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_l    public.property_listings%rowtype;
  v_id   uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.user_asset_class_unlocks
                  where user_id = v_user and class_id = 'real_estate') then
    return jsonb_build_object('status','locked');
  end if;
  select * into v_l from public.property_listings where id = p_listing and available for update;
  if not found then return jsonb_build_object('status','unavailable'); end if;
  if (select cash_balance from public.profiles where id = v_user) < v_l.value then
    return jsonb_build_object('status','insufficient_cash');
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'property_invest', -v_l.value, 'property', v_l.id::text);

  insert into public.user_properties
    (user_id, name, type_id, value, rent_rate, invested_basis, next_decision_at)
  values (v_user, v_l.name, v_l.type_id, v_l.value, v_l.rent_rate, v_l.value,
          now() + interval '3 hours')
  returning id into v_id;

  update public.property_listings set available = false where id = v_l.id;
  perform game.refresh_property_listings();

  return jsonb_build_object('status','bought','property_id', v_id, 'name', v_l.name);
end $$;

create or replace function public.sell_property(p_property uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_p    public.user_properties%rowtype;
  v_haircut numeric := coalesce(game.config_numeric('property_sell_haircut'), 0.05);
  v_proceeds numeric;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_p from public.user_properties
   where id = p_property and user_id = v_user and status = 'owned' for update;
  if not found then return jsonb_build_object('status','not_sellable'); end if;

  v_proceeds := round(v_p.value * (1 - v_haircut), 2);
  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'property_sale', v_proceeds, 'property', v_p.id::text);

  update public.user_properties set status = 'sold', rent_rate = 0 where id = v_p.id;
  return jsonb_build_object('status','sold','proceeds', v_proceeds);
end $$;

grant execute on function public.buy_property(uuid) to authenticated;
grant execute on function public.sell_property(uuid) to authenticated;

-- 7. Listings generator ------------------------------------------------------
create or replace function game.refresh_property_listings()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_target int := coalesce(game.config_numeric('property_listings_target'), 6)::int;
  v_have   int;
  v_type   public.property_types%rowtype;
  v_name   text;
  v_val    numeric;
begin
  select count(*) into v_have from public.property_listings where available;
  while v_have < v_target loop
    select * into v_type from public.property_types order by random() limit 1;
    select n.name into v_name from public.property_name_pool n
     where not exists (select 1 from public.property_listings l where l.available and l.name = n.name)
       and not exists (select 1 from public.user_properties p where p.name = n.name and p.status = 'owned')
     order by random() limit 1;
    exit when v_name is null;
    v_val := round((v_type.min_price * (1 + random() * 3))::numeric, 2);
    insert into public.property_listings (name, type_id, value, rent_rate)
    values (v_name, v_type.id, v_val, round((v_val * v_type.rent_yield)::numeric, 2));
    v_have := v_have + 1;
  end loop;
end $$;

select game.refresh_property_listings();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('refresh-property-listings', '*/30 * * * *',
      $cron$ select game.refresh_property_listings(); $cron$);
  end if;
end $$;

-- 8. Net worth: business_equity now also includes owned property -------------
-- (Redefine market_tick — unchanged from migration 20260722000021 except the
-- business term adds Σ user_properties.value.)
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

  -- 5. Refresh net worth. trading (cash + holdings + leverage) drives seasons;
  --    business (companies + owned property) is added for total net worth.
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
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0)
             + coalesce((select sum(pr.value) from public.user_properties pr
                          where pr.user_id = p2.id and pr.status = 'owned'), 0) as business
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
