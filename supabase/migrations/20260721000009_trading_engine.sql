-- ============================================================================
-- Migration 9: trading engine + progression unlocks
--
-- public.place_market_order() is the single entry point for trading.
-- Server-authoritative: the client sends (asset, side, quantity) and the
-- server decides the fill price (current_price ± half spread), validates
-- funds/holdings/unlocks, writes order + trade + ledger rows atomically, and
-- pushes the order's notional into the asset's flow accumulator so the next
-- tick's price responds to player supply & demand.
--
-- Normal failures (insufficient funds etc.) return a rejected receipt and a
-- persisted rejected order; malformed/cheating input raises.
-- ============================================================================

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

  -- Fill.
  insert into public.orders (user_id, asset_id, side, quantity, status, filled_at)
  values (v_user, p_asset_id, p_side, p_quantity, 'filled', now())
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
    'notional', v_notional);
end;
$$;

grant execute on function public.place_market_order(uuid, text, numeric) to authenticated;

-- ----------------------------------------------------------------------------
-- Progression: buy into a new asset class with in-game cash.
-- ----------------------------------------------------------------------------
create or replace function public.purchase_asset_class_unlock(p_class_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user    uuid := auth.uid();
  v_class   public.asset_classes%rowtype;
  v_profile public.profiles%rowtype;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  select * into v_class from public.asset_classes where id = p_class_id;
  if not found or not v_class.is_enabled then
    raise exception 'unknown or unavailable asset class';
  end if;
  if game.has_class_unlock(v_user, p_class_id) then
    return jsonb_build_object('status', 'rejected', 'reason', 'already unlocked');
  end if;

  select * into v_profile from public.profiles where id = v_user for update;
  if v_profile.cash_balance < v_class.unlock_cost then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash',
                              'required', v_class.unlock_cost);
  end if;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'class_unlock', -v_class.unlock_cost, 'class', p_class_id);

  insert into public.user_asset_class_unlocks (user_id, class_id)
  values (v_user, p_class_id);

  return jsonb_build_object('status', 'unlocked', 'class_id', p_class_id,
                            'cost', v_class.unlock_cost);
end;
$$;

grant execute on function public.purchase_asset_class_unlock(text) to authenticated;
