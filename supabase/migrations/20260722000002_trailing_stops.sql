-- ============================================================================
-- Migration 21: trailing stops (spot + leverage)
--
-- A trailing stop is a stop-loss whose level ratchets toward profit as the
-- price moves your way, and never back. For a long it climbs with the bid; for
-- a short leveraged position it falls with the ask. The trail is stored as an
-- offset (a fixed price distance, or a fraction of price when trail_is_percent).
--   Spot:     a pending sell 'stop' order with trail_offset set.
--   Leverage: trail_offset on the position; ratchets its stop_loss column.
-- The ratchet runs each tick, before triggers/liquidations are evaluated.
-- ============================================================================

alter table public.orders
  add column trail_offset numeric check (trail_offset is null or trail_offset > 0),
  add column trail_is_percent boolean not null default false;

alter table public.leveraged_positions
  add column trail_offset numeric check (trail_offset is null or trail_offset > 0),
  add column trail_is_percent boolean not null default false;

-- ----------------------------------------------------------------------------
-- Player RPC: set a trailing stop on a spot position (replaces any stop-loss).
-- p_is_percent true → p_trail is a fraction (0.05 = trail 5% below the peak).
-- ----------------------------------------------------------------------------
create or replace function public.set_trailing_stop(
  p_asset_id   uuid,
  p_trail      numeric,
  p_is_percent boolean default true
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
  v_gap     numeric;
  v_stop    numeric;
  v_id      uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_trail is null or p_trail <= 0 then raise exception 'invalid trail'; end if;
  if p_is_percent and p_trail >= 1 then
    raise exception 'percent trail must be a fraction below 1';
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active;
  if not found then raise exception 'unknown or inactive asset'; end if;

  select * into v_holding from public.holdings
   where user_id = v_user and asset_id = p_asset_id for update;
  if not found then
    return jsonb_build_object('status', 'rejected', 'reason', 'no open position');
  end if;

  v_bid := v_asset.current_price * (1 - v_asset.spread / 2);
  v_gap := case when p_is_percent then v_bid * p_trail else p_trail end;
  v_stop := round(v_bid - v_gap, 4);
  if v_stop <= 0 then
    return jsonb_build_object('status', 'rejected',
      'reason', 'trail is too large for this price');
  end if;

  update public.orders set status = 'cancelled', reject_reason = 'replaced'
   where user_id = v_user and asset_id = p_asset_id
     and status = 'pending' and side = 'sell' and order_type = 'stop';

  insert into public.orders
    (user_id, asset_id, side, order_type, quantity, limit_price, status,
     trail_offset, trail_is_percent)
  values (v_user, p_asset_id, 'sell', 'stop', v_holding.quantity, v_stop,
          'pending', p_trail, p_is_percent)
  returning id into v_id;

  perform game.evaluate_missions(v_user);
  return jsonb_build_object('status', 'protected',
                            'stop_loss_order_id', v_id, 'stop_price', v_stop);
end;
$$;

grant execute on function public.set_trailing_stop(uuid, numeric, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- Player RPC: set a trailing stop on a leveraged position.
-- ----------------------------------------------------------------------------
create or replace function public.set_leveraged_trailing_stop(
  p_position_id uuid,
  p_trail       numeric,
  p_is_percent  boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_pos   public.leveraged_positions%rowtype;
  v_asset public.assets%rowtype;
  v_mark  numeric;
  v_gap   numeric;
  v_stop  numeric;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_trail is null or p_trail <= 0 then raise exception 'invalid trail'; end if;
  if p_is_percent and p_trail >= 1 then
    raise exception 'percent trail must be a fraction below 1';
  end if;

  select * into v_pos from public.leveraged_positions
   where id = p_position_id and user_id = v_user and status = 'open' for update;
  if not found then raise exception 'no open position'; end if;

  select * into v_asset from public.assets where id = v_pos.asset_id;
  v_mark := v_asset.current_price *
              (1 + case when v_pos.side = 'long' then -1 else 1 end
                   * v_asset.spread / 2);
  v_gap := case when p_is_percent then v_mark * p_trail else p_trail end;
  v_stop := round(case when v_pos.side = 'long' then v_mark - v_gap
                       else v_mark + v_gap end, 4);

  if v_pos.side = 'long' and v_stop <= v_pos.liquidation_price then
    return jsonb_build_object('status', 'rejected',
      'reason', 'trail too tight — stop would sit below liquidation');
  elsif v_pos.side = 'short' and v_stop >= v_pos.liquidation_price then
    return jsonb_build_object('status', 'rejected',
      'reason', 'trail too tight — stop would sit above liquidation');
  end if;

  update public.leveraged_positions
     set stop_loss = v_stop, trail_offset = p_trail, trail_is_percent = p_is_percent
   where id = p_position_id;
  return jsonb_build_object('status', 'protected', 'stop_loss', v_stop);
end;
$$;

grant execute on function public.set_leveraged_trailing_stop(uuid, numeric, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- Tick engine: ratchet spot trailing stops toward the bid, then run the
-- existing trigger logic (unchanged from migration 20).
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
-- Tick engine: ratchet leveraged trailing stops toward the mark, then run the
-- existing liquidation/SL/TP logic (unchanged from migration 15).
-- ----------------------------------------------------------------------------
create or replace function game.process_leveraged_positions()
returns void
language plpgsql
as $$
declare
  v_row record;
  v_pos public.leveraged_positions%rowtype;
  v_exit numeric;
begin
  -- Ratchet: long stops climb with the bid, short stops fall with the ask.
  update public.leveraged_positions lp
     set stop_loss = case
           when lp.side = 'long' then greatest(coalesce(lp.stop_loss, 0),
                round((a.current_price * (1 - a.spread / 2))
                      - case when lp.trail_is_percent
                             then (a.current_price * (1 - a.spread / 2)) * lp.trail_offset
                             else lp.trail_offset end, 4))
           else least(coalesce(lp.stop_loss, 1e18),
                round((a.current_price * (1 + a.spread / 2))
                      + case when lp.trail_is_percent
                             then (a.current_price * (1 + a.spread / 2)) * lp.trail_offset
                             else lp.trail_offset end, 4))
         end
    from public.assets a
   where a.id = lp.asset_id and lp.status = 'open' and lp.trail_offset is not null
     and game.is_market_open(a.market_hours);

  for v_row in
    select lp.id as pos_id, a.current_price, a.spread
      from public.leveraged_positions lp
      join public.assets a on a.id = lp.asset_id
     where lp.status = 'open'
       and game.is_market_open(a.market_hours)
     order by lp.opened_at
     for update of lp
  loop
    select * into v_pos from public.leveraged_positions where id = v_row.pos_id;
    v_exit := round(v_row.current_price *
                (1 + case when v_pos.side = 'long' then -1 else 1 end
                     * v_row.spread / 2), 4);

    if (v_pos.side = 'long'  and v_exit <= v_pos.liquidation_price) or
       (v_pos.side = 'short' and v_exit >= v_pos.liquidation_price) then
      perform game.close_leveraged_position_internal(v_pos, v_exit, 'liquidation');
    elsif v_pos.stop_loss is not null and
          ((v_pos.side = 'long'  and v_exit <= v_pos.stop_loss) or
           (v_pos.side = 'short' and v_exit >= v_pos.stop_loss)) then
      perform game.close_leveraged_position_internal(v_pos, v_exit, 'stop_loss');
    elsif v_pos.take_profit is not null and
          ((v_pos.side = 'long'  and v_exit >= v_pos.take_profit) or
           (v_pos.side = 'short' and v_exit <= v_pos.take_profit)) then
      perform game.close_leveraged_position_internal(v_pos, v_exit, 'take_profit');
    end if;
  end loop;
end;
$$;
