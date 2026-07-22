-- ============================================================================
-- Migration 20: buy-side limit / stop ("future") orders
--
-- Extends the pending-order model beyond protection (which is sell-side TP/SL)
-- to player-created ENTRY orders that fill when the price reaches a target:
--   order_type 'limit' + buy = "buy the dip"   (fills when ask <= limit_price)
--   order_type 'stop'  + buy = "buy the breakout" (fills when ask >= limit_price)
-- Like protection, fills happen at the live ask (honest slippage), never the
-- trigger price. Cash is NOT reserved at placement — it is checked at fill and
-- the order is cancelled if the player can no longer afford it (so a queued
-- order can never overdraw the account).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Player RPC: queue a buy order that triggers on price. Selling to exit stays
-- with set_position_protection, so this is buy-only by design.
-- ----------------------------------------------------------------------------
create or replace function public.place_pending_order(
  p_asset_id    uuid,
  p_side        text,
  p_quantity    numeric,
  p_order_type  text,
  p_limit_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user     uuid := auth.uid();
  v_asset    public.assets%rowtype;
  v_ask      numeric;
  v_notional numeric;
  v_order_id uuid;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if p_side <> 'buy' then
    raise exception 'only buy entry orders are supported here';
  end if;
  if p_order_type not in ('limit', 'stop') then
    raise exception 'invalid order type';
  end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity <> round(p_quantity, 4) then
    raise exception 'invalid quantity';
  end if;
  if p_limit_price is null or p_limit_price <= 0 then
    raise exception 'invalid target price';
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active;
  if not found then
    raise exception 'unknown or inactive asset';
  end if;
  if not game.has_class_unlock(v_user, v_asset.class_id) then
    return jsonb_build_object('status', 'rejected', 'reason', 'asset class locked');
  end if;

  v_ask := v_asset.current_price * (1 + v_asset.spread / 2);
  v_notional := round(p_limit_price * p_quantity, 2);

  if v_notional > game.config_numeric('max_order_notional') then
    return jsonb_build_object('status', 'rejected', 'reason', 'order too large');
  elsif v_notional < 0.01 then
    return jsonb_build_object('status', 'rejected', 'reason', 'order too small');
  end if;

  -- Directionality: a limit buys below market (the dip), a stop buys above it
  -- (the breakout). The wrong side would fill instantly — that's a market order.
  if p_order_type = 'limit' and p_limit_price >= v_ask then
    return jsonb_build_object('status', 'rejected',
      'reason', 'limit price must be below the current price');
  elsif p_order_type = 'stop' and p_limit_price <= v_ask then
    return jsonb_build_object('status', 'rejected',
      'reason', 'stop price must be above the current price');
  end if;

  insert into public.orders
    (user_id, asset_id, side, order_type, quantity, limit_price, status)
  values (v_user, p_asset_id, 'buy', p_order_type, p_quantity,
          round(p_limit_price, 4), 'pending')
  returning id into v_order_id;

  return jsonb_build_object('status', 'placed', 'order_id', v_order_id,
                            'order_type', p_order_type,
                            'limit_price', round(p_limit_price, 4));
end;
$$;

grant execute on function public.place_pending_order(uuid, text, numeric, text, numeric) to authenticated;

-- ----------------------------------------------------------------------------
-- Tick engine: extend trigger execution to buy limit/stop as well as the
-- existing sell TP/SL. Sell logic is unchanged; buys are funded from cash.
-- ----------------------------------------------------------------------------
create or replace function game.execute_triggered_orders()
returns void
language plpgsql
as $$
declare
  v_o        record;
  v_held     numeric;
  v_price    numeric;
  v_notional numeric;
  v_cash     numeric;
  v_trade_id uuid;
begin
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
      -- Protection (TP/SL): fill at the live bid, one-cancels-other on close.
      select quantity into v_held from public.holdings
       where user_id = v_o.user_id and asset_id = v_o.asset_id;

      if coalesce(v_held, 0) < v_o.quantity then
        update public.orders
           set status = 'cancelled', reject_reason = 'position closed'
         where id = v_o.id;
        continue;
      end if;

      v_price := greatest(round(v_o.current_price * (1 - v_o.spread / 2), 4), 0.01);
      v_notional := round(v_price * v_o.quantity, 2);

      insert into public.trades (order_id, user_id, asset_id, side, quantity, price, notional)
      values (v_o.id, v_o.user_id, v_o.asset_id, 'sell', v_o.quantity, v_price, v_notional)
      returning id into v_trade_id;

      insert into public.transactions
        (user_id, type, cash_delta, asset_id, qty_delta, ref_type, ref_id)
      values (v_o.user_id, 'trade_sell', v_notional, v_o.asset_id, -v_o.quantity,
              'trade', v_trade_id::text);

      update public.assets set flow = flow - v_notional where id = v_o.asset_id;
      update public.orders set status = 'filled', filled_at = now() where id = v_o.id;
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
      -- Buy entry (limit/stop): fill at the live ask, funded from cash. If the
      -- player can no longer afford it, cancel rather than overdraw.
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
