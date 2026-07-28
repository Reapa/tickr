-- ============================================================================
-- Slots — the second arcade game
--
-- Design constraints, in priority order:
--
--   1. IT MUST NOT TOUCH THE LEADERBOARD. Slots pays real cash (the owner's
--      call), and cash is part of trading_net_worth, which drives season
--      scoring. So the running arcade P/L is tracked and then moved OFF the
--      trading track and ONTO the business track inside the tick:
--
--        trading_net_worth = cash + holdings + leverage - arcade_net_pnl
--        business_equity   = companies + property + gear + arcade_net_pnl
--
--      Total net worth is exactly what it was; the season figure is blind to
--      whether you won or lost at a slot machine. Symmetric in both directions,
--      so you can neither win a season on a jackpot nor lose one on a bad run.
--
--   2. THE ODDS ARE REAL AND CHECKABLE. Reels are rolled server-side from a
--      weighted symbol table, and the payout table lives in the database so the
--      exact return-to-player can be computed in closed form — see
--      game.slot_rtp(), which the test suite asserts against. Nothing about the
--      odds is hidden in application code.
--
--   3. IT IS A CASH SINK. RTP is ~91%, so slots drains the economy over time.
--      That is deliberate: this game has many faucets (dividends, rent,
--      business revenue, fishing) and almost no drains.
--
--   4. IT CANNOT LAUNDER A FORTUNE. Bets are capped per spin, and losing is
--      the expected outcome, so there is no strategy in which this beats
--      trading.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Config
-- ----------------------------------------------------------------------------
insert into public.game_config (key, value, description) values
  ('slots_enabled',  '1',    'Master switch for the slot machine.'),
  ('slots_min_bet',  '10',   'Smallest allowed stake per spin.'),
  ('slots_max_bet',  '5000', 'Largest allowed stake per spin — keeps the '
                             'arcade a diversion, not a wealth strategy.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Ledger types
-- ----------------------------------------------------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward', 'passive_income',
    'company_invest', 'company_sale', 'property_invest', 'property_sale',
    'fishing_gear', 'fishing_sale', 'arcade_bet', 'arcade_win'
  ));
alter table public.transactions add constraint transactions_arcade_bet_debits
  check (type <> 'arcade_bet' or (cash_delta < 0 and qty_delta = 0));
alter table public.transactions add constraint transactions_arcade_win_credits
  check (type <> 'arcade_win' or (cash_delta > 0 and qty_delta = 0));

-- ----------------------------------------------------------------------------
-- 3. The reel
--
-- One weighted strip, used for all three reels independently. Payouts are
-- multiples of the stake: pay3 for three of a kind, pay2 for exactly two of
-- the higher symbols (which is what keeps a losing session from feeling dead).
-- ----------------------------------------------------------------------------
create table public.slot_symbols (
  code       text primary key,
  name       text not null,
  weight     numeric not null check (weight > 0),
  pay3       numeric not null check (pay3 >= 0),
  pay2       numeric not null default 0 check (pay2 >= 0),
  sort_order int not null default 0
);
grant select on public.slot_symbols to anon, authenticated;

insert into public.slot_symbols (code, name, weight, pay3, pay2, sort_order) values
  ('coin',   'Coin',    30, 6,   0,  1),
  ('chart',  'Chart',   24, 10,  0,  2),
  ('bull',   'Bull',    18, 20,  2,  3),
  ('bear',   'Bear',    18, 20,  2,  4),
  ('gem',    'Diamond',  9, 50,  4,  5),
  ('rocket', 'Rocket',   5, 120, 6,  6),
  ('seven',  'Lucky 7',  2, 500, 10, 7);

-- The exact return-to-player, in closed form, straight from the table above.
-- Three independent reels drawn from the same strip:
--   P(three of a kind of s) = p_s^3
--   P(exactly two of s)     = 3 * p_s^2 * (1 - p_s)
-- No simulation, no guessing — if someone edits a payout, this moves and the
-- test suite says so.
create or replace function game.slot_rtp()
returns numeric
language sql
stable
as $$
  with t as (select sum(weight) as total from public.slot_symbols)
  select round(sum(
      power(s.weight / t.total, 3) * s.pay3
    + 3 * power(s.weight / t.total, 2) * (1 - s.weight / t.total) * s.pay2
  ), 6)
  from public.slot_symbols s, t;
$$;

comment on function game.slot_rtp() is
  'Exact expected payout per unit staked, derived from slot_symbols. Below 1 '
  'by design — the difference is the house edge, which is a cash sink.';

-- ----------------------------------------------------------------------------
-- 4. Player arcade state. net_pnl is the number that keeps slots off the
--    season leaderboard.
-- ----------------------------------------------------------------------------
create table public.user_arcade (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  net_pnl     numeric(18,2) not null default 0,  -- lifetime won minus wagered
  spins       int not null default 0,
  wagered     numeric(18,2) not null default 0,
  won         numeric(18,2) not null default 0,
  biggest_win numeric(18,2) not null default 0,
  updated_at  timestamptz not null default now()
);
alter table public.user_arcade enable row level security;
create policy "own arcade readable" on public.user_arcade
  for select using (user_id = auth.uid());
grant select on public.user_arcade to authenticated;

-- Recent spins, for the on-screen history strip.
create table public.slot_spins (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles (id) on delete cascade,
  bet       numeric(18,2) not null,
  reels     text[] not null,
  payout    numeric(18,2) not null,
  spun_at   timestamptz not null default now()
);
create index slot_spins_user_idx on public.slot_spins (user_id, spun_at desc);
alter table public.slot_spins enable row level security;
create policy "own spins readable" on public.slot_spins
  for select using (user_id = auth.uid());
grant select on public.slot_spins to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_arcade;
  end if;
end $$;

create or replace function game.ensure_arcade(p_user uuid)
returns void
language sql
security definer
set search_path = public, game
as $$
  insert into public.user_arcade (user_id) values (p_user)
  on conflict (user_id) do nothing;
$$;

create or replace function game.arcade_on_new_profile()
returns trigger
language plpgsql
security definer
set search_path = public, game
as $$
begin
  insert into public.user_arcade (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists profiles_arcade_row on public.profiles;
create trigger profiles_arcade_row
  after insert on public.profiles
  for each row execute function game.arcade_on_new_profile();

insert into public.user_arcade (user_id)
select id from public.profiles on conflict (user_id) do nothing;

-- ----------------------------------------------------------------------------
-- 5. The spin
-- ----------------------------------------------------------------------------
create or replace function game.draw_reel()
returns text
language sql
as $$
  select code from public.slot_symbols
   order by -ln(1 - random()) / weight   -- exponential-race weighted draw
   limit 1;
$$;

create or replace function public.spin_slots(p_bet numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user    uuid := auth.uid();
  v_min     numeric := game.config_numeric('slots_min_bet');
  v_max     numeric := game.config_numeric('slots_max_bet');
  v_cash    numeric;
  v_reels   text[];
  v_pair    text;
  v_sym     public.slot_symbols%rowtype;
  v_mult    numeric := 0;
  v_payout  numeric := 0;
  v_kind    text := 'lose';
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if game.config_numeric('slots_enabled') < 1 then
    return jsonb_build_object('status', 'rejected', 'reason', 'the arcade is closed');
  end if;

  p_bet := round(coalesce(p_bet, 0), 2);
  if p_bet < v_min then
    return jsonb_build_object('status', 'rejected',
      'reason', format('minimum bet is %s', v_min));
  end if;
  if p_bet > v_max then
    return jsonb_build_object('status', 'rejected',
      'reason', format('maximum bet is %s', v_max));
  end if;

  perform game.ensure_arcade(v_user);
  select cash_balance into v_cash from public.profiles where id = v_user for update;
  if v_cash < p_bet then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash');
  end if;

  v_reels := array[game.draw_reel(), game.draw_reel(), game.draw_reel()];

  -- Three of a kind, else exactly two of a paying symbol.
  if v_reels[1] = v_reels[2] and v_reels[2] = v_reels[3] then
    select * into v_sym from public.slot_symbols where code = v_reels[1];
    v_mult := v_sym.pay3;
    v_kind := case when v_sym.code = 'seven' then 'jackpot' else 'triple' end;
  else
    select s.code into v_pair
      from (select t.code, count(*) as cnt
              from unnest(v_reels) as t(code) group by t.code) c
      join public.slot_symbols s on s.code = c.code
     where c.cnt = 2 and s.pay2 > 0
     limit 1;
    if v_pair is not null then
      select * into v_sym from public.slot_symbols where code = v_pair;
      v_mult := v_sym.pay2;
      v_kind := 'pair';
    end if;
  end if;

  v_payout := round(p_bet * v_mult, 2);

  -- The stake always leaves; the payout comes back as its own credit. Two rows,
  -- so the ledger shows what was risked as well as what was returned.
  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (v_user, 'arcade_bet', -p_bet, 'slots');
  if v_payout > 0 then
    insert into public.transactions (user_id, type, cash_delta, ref_type)
    values (v_user, 'arcade_win', v_payout, 'slots');
  end if;

  insert into public.slot_spins (user_id, bet, reels, payout)
  values (v_user, p_bet, v_reels, v_payout);

  -- Keep the history strip short; nobody scrolls a thousand spins.
  delete from public.slot_spins
   where user_id = v_user
     and id not in (select id from public.slot_spins
                     where user_id = v_user
                     order by spun_at desc limit 25);

  update public.user_arcade
     set net_pnl = net_pnl + v_payout - p_bet,
         spins = spins + 1,
         wagered = wagered + p_bet,
         won = won + v_payout,
         biggest_win = greatest(biggest_win, v_payout),
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object(
    'status', 'spun', 'reels', to_jsonb(v_reels), 'bet', p_bet,
    'multiplier', v_mult, 'payout', v_payout, 'net', v_payout - p_bet,
    'kind', v_kind,
    'symbol', case when v_mult > 0 then v_sym.code else null end,
    'symbol_name', case when v_mult > 0 then v_sym.name else null end);
end $$;

grant execute on function public.spin_slots(numeric) to authenticated;

-- The odds, published. A player can read the whole payout table and the exact
-- RTP — this is a game, not a trap.
create or replace function public.get_slot_odds()
returns jsonb
language sql
stable
security definer
set search_path = public, game
as $$
  select jsonb_build_object(
    'rtp', game.slot_rtp(),
    'min_bet', game.config_numeric('slots_min_bet'),
    'max_bet', game.config_numeric('slots_max_bet'),
    'symbols', (select jsonb_agg(jsonb_build_object(
                  'code', code, 'name', name, 'pay3', pay3, 'pay2', pay2,
                  'chance', round(weight / (select sum(weight) from public.slot_symbols), 4))
                  order by sort_order)
                  from public.slot_symbols));
$$;

grant execute on function public.get_slot_odds() to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Net worth: move the arcade P/L off the trading track.
--    Redefined from 20260722000027_fishing.sql — the ONLY changes are the two
--    arcade terms in the trading/business split.
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
  v_flow_cap     numeric := game.config_numeric('flow_cap_multiple');
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
           least(greatest(a.flow * v_decay, -v_flow_cap * a.liquidity),
                 v_flow_cap * a.liquidity) as new_flow,
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
             adv2.new_fair * (1 + game.flow_impact(adv2.new_flow, adv2.liquidity,
                                                   adv2.impact_coef))
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
                            where lp.user_id = p2.id and lp.status = 'open'), 0)
               -- Arcade winnings sit in cash, so subtract them back out: the
               -- season figure must reflect trading, not luck.
               - coalesce((select ua.net_pnl from public.user_arcade ua
                            where ua.user_id = p2.id), 0) as trading,
             coalesce((select sum(case
                             when uc.status = 'public' and uc.public_asset_id is not null
                             then uc.founder_shares * coalesce(pa.current_price, 0)
                             else uc.valuation end)
                         from public.user_companies uc
                         left join public.assets pa on pa.id = uc.public_asset_id
                        where uc.user_id = p2.id and uc.status <> 'sold'), 0)
             + coalesce((select sum(pr.value) from public.user_properties pr
                          where pr.user_id = p2.id and pr.status = 'owned'), 0)
             + coalesce((select uf.gear_value from public.user_fishery uf
                          where uf.user_id = p2.id), 0)
             -- ...and add them here instead, so total net worth is unchanged.
             + coalesce((select ua.net_pnl from public.user_arcade ua
                          where ua.user_id = p2.id), 0) as business
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
