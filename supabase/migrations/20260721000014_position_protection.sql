-- ============================================================================
-- Migration 14: take-profit / stop-loss ("position protection")
--
-- Model: pending SELL orders that the tick engine executes when the bid
-- crosses the trigger price.
--   order_type 'limit' + sell  = take profit  (fills when bid >= limit_price)
--   order_type 'stop'  + sell  = stop loss    (fills when bid <= limit_price)
-- Fills happen at the live bid, not the trigger price — so stops can fill
-- through the level on a gap, which is honest and teaches slippage.
-- One TP and one SL per position (setting a new one replaces the old).
-- When a fill (manual or triggered) empties the position, sibling pending
-- sells are auto-cancelled — natural one-cancels-other behavior.
-- ============================================================================

alter table public.orders drop constraint orders_order_type_check;
alter table public.orders add constraint orders_order_type_check
  check (order_type in ('market', 'limit', 'stop'));
alter table public.orders add constraint orders_stop_price_required
  check (order_type <> 'stop' or limit_price is not null);

-- ----------------------------------------------------------------------------
-- Player RPC: set TP and/or SL on a held position (full position size).
-- ----------------------------------------------------------------------------
create or replace function public.set_position_protection(
  p_asset_id    uuid,
  p_take_profit numeric default null,
  p_stop_loss   numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user    uuid := auth.uid();
  v_asset   public.assets%rowtype;
  v_holding public.holdings%rowtype;
  v_bid     numeric;
  v_tp_id   uuid;
  v_sl_id   uuid;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;
  if p_take_profit is null and p_stop_loss is null then
    raise exception 'set a take profit, a stop loss, or both';
  end if;
  if p_take_profit is not null and p_take_profit <= 0 then
    raise exception 'invalid take profit price';
  end if;
  if p_stop_loss is not null and p_stop_loss <= 0 then
    raise exception 'invalid stop loss price';
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active;
  if not found then
    raise exception 'unknown or inactive asset';
  end if;

  select * into v_holding from public.holdings
   where user_id = v_user and asset_id = p_asset_id
   for update;
  if not found then
    return jsonb_build_object('status', 'rejected', 'reason', 'no open position');
  end if;

  v_bid := v_asset.current_price * (1 - v_asset.spread / 2);

  if p_take_profit is not null and p_take_profit <= v_bid then
    return jsonb_build_object('status', 'rejected',
      'reason', 'take profit must be above the current price');
  end if;
  if p_stop_loss is not null and p_stop_loss >= v_bid then
    return jsonb_build_object('status', 'rejected',
      'reason', 'stop loss must be below the current price');
  end if;

  if p_take_profit is not null then
    update public.orders
       set status = 'cancelled', reject_reason = 'replaced'
     where user_id = v_user and asset_id = p_asset_id
       and status = 'pending' and side = 'sell' and order_type = 'limit';
    insert into public.orders
      (user_id, asset_id, side, order_type, quantity, limit_price, status)
    values (v_user, p_asset_id, 'sell', 'limit', v_holding.quantity,
            round(p_take_profit, 4), 'pending')
    returning id into v_tp_id;
  end if;

  if p_stop_loss is not null then
    update public.orders
       set status = 'cancelled', reject_reason = 'replaced'
     where user_id = v_user and asset_id = p_asset_id
       and status = 'pending' and side = 'sell' and order_type = 'stop';
    insert into public.orders
      (user_id, asset_id, side, order_type, quantity, limit_price, status)
    values (v_user, p_asset_id, 'sell', 'stop', v_holding.quantity,
            round(p_stop_loss, 4), 'pending')
    returning id into v_sl_id;
  end if;

  -- The educational layer notices risk management (set_stop_loss mission).
  perform game.evaluate_missions(v_user);

  return jsonb_build_object('status', 'protected',
                            'take_profit_order_id', v_tp_id,
                            'stop_loss_order_id', v_sl_id);
end;
$$;

create or replace function public.cancel_pending_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  update public.orders
     set status = 'cancelled', reject_reason = 'cancelled by player'
   where id = p_order_id and user_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'no pending order to cancel';
  end if;
end;
$$;

grant execute on function public.set_position_protection(uuid, numeric, numeric) to authenticated;
grant execute on function public.cancel_pending_order(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Tick engine: execute due triggers at the freshly ticked prices.
-- Called from game.market_tick() after prices move, before net worth.
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
  v_trade_id uuid;
begin
  for v_o in
    select o.id, o.user_id, o.asset_id, o.order_type, o.quantity,
           a.current_price, a.spread
      from public.orders o
      join public.assets a on a.id = o.asset_id
     where o.status = 'pending' and o.side = 'sell'
       and (   (o.order_type = 'limit'
                and a.current_price * (1 - a.spread / 2) >= o.limit_price)
            or (o.order_type = 'stop'
                and a.current_price * (1 - a.spread / 2) <= o.limit_price))
     order by o.created_at
     for update of o
  loop
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

    -- One-cancels-other: drop sibling pending sells the position can no
    -- longer cover.
    update public.orders o2
       set status = 'cancelled', reject_reason = 'position closed'
     where o2.user_id = v_o.user_id and o2.asset_id = v_o.asset_id
       and o2.status = 'pending' and o2.side = 'sell'
       and o2.quantity > coalesce((select h.quantity from public.holdings h
                                    where h.user_id = o2.user_id
                                      and h.asset_id = o2.asset_id), 0);

    perform game.evaluate_missions(v_o.user_id);
  end loop;
end;
$$;
