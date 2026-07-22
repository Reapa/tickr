-- ============================================================================
-- Migration 30: realized profit / loss on closing sells
--
-- Every closing SELL now records how much cash profit or loss it locked in,
-- so the portfolio's "Recent orders" can show "+$X" / "−$X" — especially when
-- a stop-loss or take-profit fires server-side and the player never sees the
-- fill happen. Realized P/L = (fill_price − avg_cost) × quantity, captured at
-- fill time from the position's weighted-average cost.
--
--   realized_pnl   — cash gained (+) or lost (−) on the close (null for buys)
--   close_avg_cost — the position's avg cost/unit at close (for a % + display)
--
-- Both are set on the three sell-fill paths: place_market_order (manual sell /
-- "Close position") and game.execute_triggered_orders (SL / TP / trailing).
-- ============================================================================

alter table public.orders
  add column if not exists realized_pnl   numeric(18,2),
  add column if not exists close_avg_cost numeric(18,4);

-- ----------------------------------------------------------------------------
-- place_market_order: unchanged except that a sell fill now stamps the order
-- with its realized P/L and cost basis, and returns them in the receipt.
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

  -- record a rejected order and build the receipt
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
  for update;  -- serialize flow updates per asset
  if not found then
    raise exception 'unknown or inactive asset';
  end if;

  -- Lock the profile row: serializes a user's concurrent orders.
  select * into v_profile from public.profiles where id = v_user for update;

  -- Server-decided fill price: buyers pay the half-spread, sellers give it up.
  v_price := round(v_asset.current_price *
               (1 + case when p_side = 'buy' then 1 else -1 end * v_asset.spread / 2), 4);
  v_price := greatest(v_price, 0.01);
  v_notional := round(v_price * p_quantity, 2);

  -- Validation with persisted rejections.
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

  -- Realized P/L on a closing sell (v_holding is the pre-sale position).
  if p_side = 'sell' then
    v_avg_cost := v_holding.avg_cost;
    v_realized := round((v_price - v_avg_cost) * p_quantity, 2);
  end if;

  -- Fill.
  insert into public.orders
    (user_id, asset_id, side, quantity, status, filled_at, realized_pnl, close_avg_cost)
  values (v_user, p_asset_id, p_side, p_quantity, 'filled', now(), v_realized, v_avg_cost)
  returning id into v_order_id;

  insert into public.trades (order_id, user_id, asset_id, side, quantity, price, notional)
  values (v_order_id, v_user, p_asset_id, p_side, p_quantity, v_price, v_notional)
  returning id into v_trade_id;

  -- Ledger row applies cash + holdings via trigger.
  insert into public.transactions (user_id, type, cash_delta, asset_id, qty_delta, ref_type, ref_id)
  values (v_user,
          case when p_side = 'buy' then 'trade_buy' else 'trade_sell' end,
          case when p_side = 'buy' then -v_notional else v_notional end,
          p_asset_id,
          case when p_side = 'buy' then p_quantity else -p_quantity end,
          'trade', v_trade_id::text);

  -- Push order flow into the simulation: net buying lifts the next tick's price.
  update public.assets
     set flow = flow + case when p_side = 'buy' then v_notional else -v_notional end
   where id = p_asset_id;

  update public.profiles set xp = xp + v_xp, updated_at = now() where id = v_user;

  -- Educational layer reacts to the trade (defined in migration 11).
  perform game.evaluate_missions(v_user);

  return jsonb_build_object(
    'status', 'filled',
    'order_id', v_order_id,
    'trade_id', v_trade_id,
    'price', v_price,
    'quantity', p_quantity,
    'notional', v_notional,
    'realized_pnl', v_realized);
end;
$$;

grant execute on function public.place_market_order(uuid, text, numeric) to authenticated;

-- ----------------------------------------------------------------------------
-- execute_triggered_orders: same tick engine as migration 21 (trailing stops),
-- with realized P/L + cost basis stamped onto each triggered SELL fill.
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
  v_price    numeric;
  v_notional numeric;
  v_cash     numeric;
  v_trade_id uuid;
begin
  -- Ratchet: pull each trailing stop up to (bid − trail), never down.
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
             realized_pnl = v_realized, close_avg_cost = v_avg_cost
       where id = v_o.id;
      update public.profiles
         set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
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

-- ----------------------------------------------------------------------------
-- get_recent_activity: expose realized P/L on closing spot sells so the public
-- "Live" feed can show "closed BTC +$4.2k". Buys / opens carry null.
-- Dropped first: adding a return column changes the row type, which
-- create-or-replace cannot do in place.
-- ----------------------------------------------------------------------------
drop function if exists public.get_recent_activity(int);

create or replace function public.get_recent_activity(p_limit int default 30)
returns table (
  at           timestamptz,
  trader       text,
  symbol       text,
  kind         text,
  side         text,
  notional     numeric,
  leverage     int,
  realized_pnl numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select * from (
    select t.created_at as at, p.display_name as trader, a.symbol,
           'spot'::text as kind, t.side, t.notional, null::int as leverage,
           o.realized_pnl
      from public.trades t
      join public.assets a on a.id = t.asset_id
      join public.profiles p on p.id = t.user_id
      left join public.orders o on o.id = t.order_id
     where t.notional >= 1000
    union all
    select lp.opened_at, p.display_name, a.symbol,
           'leverage'::text, lp.side, lp.margin * lp.leverage, lp.leverage,
           null::numeric
      from public.leveraged_positions lp
      join public.assets a on a.id = lp.asset_id
      join public.profiles p on p.id = lp.user_id
  ) feed
  order by at desc
  limit least(greatest(p_limit, 1), 100);
$$;

grant execute on function public.get_recent_activity(int) to authenticated;
