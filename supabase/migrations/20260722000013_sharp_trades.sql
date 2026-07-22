-- ============================================================================
-- Migration 32: "Sharp Trade" variable-ratio XP bonus
--
-- Flat 10 XP/trade is a pure fixed-ratio schedule — no variance, no
-- anticipation. This layers a variable-ratio bonus on top: every PROFITABLE
-- close rolls a ~15% chance of a 2–10× XP multiplier, surfaced as a "Sharp
-- Trade" moment. The roll is server-side so it can't be gamed, and the rolled
-- multiplier is stamped on the order for auditability + client display.
--
-- Anti-farm: only profitable closes qualify, and a wash trade (buy then sell
-- immediately) loses the round-trip spread → negative P/L → never eligible. A
-- minimum notional stops dust-trade spam. Distribution is skewed low (2–3
-- common, 10 rare) so the big multiplier stays a genuine surprise.
-- ============================================================================

alter table public.orders add column if not exists xp_multiplier int;

insert into public.game_config (key, value, description) values
  ('sharp_trade_chance', '0.15',
   'Chance a profitable close rolls a bonus XP multiplier ("Sharp Trade").'),
  ('sharp_trade_min_notional', '250',
   'Minimum close notional (USD) eligible for the Sharp Trade bonus roll.')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- The roll: returns the XP multiplier (1 = no bonus, 2–10 = Sharp Trade).
-- Skewed toward small multipliers via random()² so 10× is rare.
-- ----------------------------------------------------------------------------
create or replace function game.roll_sharp_trade(p_notional numeric, p_pnl numeric)
returns int
language sql
volatile
set search_path = public, game
as $$
  select case
    when p_pnl > 0
     and p_notional >= game.config_numeric('sharp_trade_min_notional')
     and random() < game.config_numeric('sharp_trade_chance')
    then 2 + floor(power(random(), 2) * 9)::int
    else 1
  end;
$$;

-- ----------------------------------------------------------------------------
-- place_market_order: a profitable sell now rolls the bonus, grants XP × the
-- multiplier, stamps it on the order, and returns it in the receipt.
-- ----------------------------------------------------------------------------
create or replace function public.place_market_order(
  p_asset_id uuid,
  p_side     text,
  p_quantity numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user     uuid := auth.uid();
  v_asset    public.assets%rowtype;
  v_profile  public.profiles%rowtype;
  v_holding  public.holdings%rowtype;
  v_price    numeric;
  v_notional numeric;
  v_order_id uuid;
  v_trade_id uuid;
  v_xp       int := game.config_numeric('xp_per_trade')::int;
  v_avg_cost numeric;   -- position avg cost at close (sells only)
  v_realized numeric;   -- realized P/L on a closing sell
  v_mult     int := 1;  -- Sharp Trade XP multiplier (sells only)
  v_reason   text;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if p_side not in ('buy', 'sell') then
    raise exception 'invalid side %', p_side;
  end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity <> round(p_quantity, 4) then
    raise exception 'invalid quantity';
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active
  for update;
  if not found then
    raise exception 'unknown or inactive asset';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  v_price := round(v_asset.current_price *
               (1 + case when p_side = 'buy' then 1 else -1 end * v_asset.spread / 2), 4);
  v_price := greatest(v_price, 0.01);
  v_notional := round(v_price * p_quantity, 2);

  if not game.is_market_open(v_asset.market_hours) then
    v_reason := 'market closed';
  elsif not game.has_class_unlock(v_user, v_asset.class_id) then
    v_reason := 'asset class locked';
  elsif v_notional > game.config_numeric('max_order_notional') then
    v_reason := 'order too large';
  elsif v_notional < 0.01 then
    v_reason := 'order too small';
  elsif p_side = 'buy' and v_profile.cash_balance < v_notional then
    v_reason := 'insufficient cash';
  elsif p_side = 'sell' then
    select * into v_holding from public.holdings
     where user_id = v_user and asset_id = p_asset_id;
    if not found or v_holding.quantity < p_quantity then
      v_reason := 'insufficient holdings';
    end if;
  end if;

  if v_reason is not null then
    insert into public.orders (user_id, asset_id, side, quantity, status, reject_reason)
    values (v_user, p_asset_id, p_side, p_quantity, 'rejected', v_reason)
    returning id into v_order_id;
    return jsonb_build_object('status', 'rejected', 'reason', v_reason,
                              'order_id', v_order_id);
  end if;

  -- Realized P/L + Sharp Trade roll on a closing sell.
  if p_side = 'sell' then
    v_avg_cost := v_holding.avg_cost;
    v_realized := round((v_price - v_avg_cost) * p_quantity, 2);
    v_mult := game.roll_sharp_trade(v_notional, v_realized);
  end if;

  insert into public.orders
    (user_id, asset_id, side, quantity, status, filled_at,
     realized_pnl, close_avg_cost, xp_multiplier)
  values (v_user, p_asset_id, p_side, p_quantity, 'filled', now(),
          v_realized, v_avg_cost, case when p_side = 'sell' then v_mult end)
  returning id into v_order_id;

  insert into public.trades (order_id, user_id, asset_id, side, quantity, price, notional)
  values (v_order_id, v_user, p_asset_id, p_side, p_quantity, v_price, v_notional)
  returning id into v_trade_id;

  insert into public.transactions (user_id, type, cash_delta, asset_id, qty_delta, ref_type, ref_id)
  values (v_user,
          case when p_side = 'buy' then 'trade_buy' else 'trade_sell' end,
          case when p_side = 'buy' then -v_notional else v_notional end,
          p_asset_id,
          case when p_side = 'buy' then p_quantity else -p_quantity end,
          'trade', v_trade_id::text);

  update public.assets
     set flow = flow + case when p_side = 'buy' then v_notional else -v_notional end
   where id = p_asset_id;

  update public.profiles set xp = xp + v_xp * v_mult, updated_at = now()
   where id = v_user;

  perform game.evaluate_missions(v_user);

  return jsonb_build_object(
    'status', 'filled',
    'order_id', v_order_id,
    'trade_id', v_trade_id,
    'price', v_price,
    'quantity', p_quantity,
    'notional', v_notional,
    'realized_pnl', v_realized,
    'xp_multiplier', case when p_side = 'sell' then v_mult end);
end;
$$;

grant execute on function public.place_market_order(uuid, text, numeric) to authenticated;

-- ----------------------------------------------------------------------------
-- execute_triggered_orders: a profitable triggered sell (a take-profit, or a
-- trailing stop that locked in gains) rolls the Sharp Trade bonus too.
-- ----------------------------------------------------------------------------
create or replace function game.execute_triggered_orders()
returns void
language plpgsql
as $$
declare
  v_o        record;
  v_held     numeric;
  v_avg_cost numeric;
  v_realized numeric;
  v_mult     int;
  v_price    numeric;
  v_notional numeric;
  v_cash     numeric;
  v_trade_id uuid;
begin
  update public.orders o
     set limit_price = greatest(o.limit_price,
           round((a.current_price * (1 - a.spread / 2))
                 - case when o.trail_is_percent
                        then (a.current_price * (1 - a.spread / 2)) * o.trail_offset
                        else o.trail_offset end, 4))
    from public.assets a
   where a.id = o.asset_id
     and o.status = 'pending' and o.side = 'sell' and o.order_type = 'stop'
     and o.trail_offset is not null
     and game.is_market_open(a.market_hours);

  for v_o in
    select o.id, o.user_id, o.asset_id, o.side, o.order_type, o.quantity,
           a.current_price, a.spread
      from public.orders o
      join public.assets a on a.id = o.asset_id
     where o.status = 'pending'
       and game.is_market_open(a.market_hours)
       and (   (o.side = 'sell' and o.order_type = 'limit'
                and a.current_price * (1 - a.spread / 2) >= o.limit_price)
            or (o.side = 'sell' and o.order_type = 'stop'
                and a.current_price * (1 - a.spread / 2) <= o.limit_price)
            or (o.side = 'buy' and o.order_type = 'limit'
                and a.current_price * (1 + a.spread / 2) <= o.limit_price)
            or (o.side = 'buy' and o.order_type = 'stop'
                and a.current_price * (1 + a.spread / 2) >= o.limit_price))
     order by o.created_at
     for update of o
  loop
    if v_o.side = 'sell' then
      select quantity, avg_cost into v_held, v_avg_cost from public.holdings
       where user_id = v_o.user_id and asset_id = v_o.asset_id;

      if coalesce(v_held, 0) < v_o.quantity then
        update public.orders
           set status = 'cancelled', reject_reason = 'position closed'
         where id = v_o.id;
        continue;
      end if;

      v_price := greatest(round(v_o.current_price * (1 - v_o.spread / 2), 4), 0.01);
      v_notional := round(v_price * v_o.quantity, 2);
      v_realized := round((v_price - v_avg_cost) * v_o.quantity, 2);
      v_mult := game.roll_sharp_trade(v_notional, v_realized);

      insert into public.trades (order_id, user_id, asset_id, side, quantity, price, notional)
      values (v_o.id, v_o.user_id, v_o.asset_id, 'sell', v_o.quantity, v_price, v_notional)
      returning id into v_trade_id;

      insert into public.transactions
        (user_id, type, cash_delta, asset_id, qty_delta, ref_type, ref_id)
      values (v_o.user_id, 'trade_sell', v_notional, v_o.asset_id, -v_o.quantity,
              'trade', v_trade_id::text);

      update public.assets set flow = flow - v_notional where id = v_o.asset_id;
      update public.orders
         set status = 'filled', filled_at = now(),
             realized_pnl = v_realized, close_avg_cost = v_avg_cost,
             xp_multiplier = v_mult
       where id = v_o.id;
      update public.profiles
         set xp = xp + game.config_numeric('xp_per_trade')::int * v_mult,
             updated_at = now()
       where id = v_o.user_id;

      update public.orders o2
         set status = 'cancelled', reject_reason = 'position closed'
       where o2.user_id = v_o.user_id and o2.asset_id = v_o.asset_id
         and o2.status = 'pending' and o2.side = 'sell'
         and o2.quantity > coalesce((select h.quantity from public.holdings h
                                      where h.user_id = o2.user_id
                                        and h.asset_id = o2.asset_id), 0);

      perform game.evaluate_missions(v_o.user_id);

    else
      v_price := greatest(round(v_o.current_price * (1 + v_o.spread / 2), 4), 0.01);
      v_notional := round(v_price * v_o.quantity, 2);

      select cash_balance into v_cash from public.profiles
       where id = v_o.user_id for update;

      if coalesce(v_cash, 0) < v_notional then
        update public.orders
           set status = 'cancelled', reject_reason = 'insufficient cash'
         where id = v_o.id;
        continue;
      end if;

      insert into public.trades (order_id, user_id, asset_id, side, quantity, price, notional)
      values (v_o.id, v_o.user_id, v_o.asset_id, 'buy', v_o.quantity, v_price, v_notional)
      returning id into v_trade_id;

      insert into public.transactions
        (user_id, type, cash_delta, asset_id, qty_delta, ref_type, ref_id)
      values (v_o.user_id, 'trade_buy', -v_notional, v_o.asset_id, v_o.quantity,
              'trade', v_trade_id::text);

      update public.assets set flow = flow + v_notional where id = v_o.asset_id;
      update public.orders set status = 'filled', filled_at = now() where id = v_o.id;
      update public.profiles
         set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
       where id = v_o.user_id;

      perform game.evaluate_missions(v_o.user_id);
    end if;
  end loop;
end;
$$;
