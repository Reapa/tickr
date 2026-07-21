-- ============================================================================
-- Migration 15: leveraged trading ("the broker")
--
-- CFD-style leveraged positions, long or short. The player posts margin;
-- the position controls margin × leverage of notional. P&L moves with the
-- price; when losses reach the posted margin the position auto-liquidates.
-- Cash can never go negative: the maximum loss is always the margin.
--
--   entry (long)  = ask;  mark/exit = bid;  pnl = qty · (exit − entry)
--   entry (short) = bid;  mark/exit = ask;  pnl = qty · (entry − exit)
--   liquidation   = entry · (1 ∓ 1/leverage)   (∓: long −, short +)
--
-- Progression: requires the 'margin' broker-license unlock (bought with
-- in-game cash like any asset class). 5×/10× available immediately after
-- unlock; 50× needs level 5; 100× needs level 10.
-- All cash flows are ledger rows ('margin_open' / 'margin_close').
-- ============================================================================

-- New ledger types for margin flows.
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close'
  ));
alter table public.transactions add constraint transactions_margin_open_debits
  check (type <> 'margin_open' or (cash_delta < 0 and qty_delta = 0));
alter table public.transactions add constraint transactions_margin_close_credits
  check (type <> 'margin_close' or (cash_delta >= 0 and qty_delta = 0));

create table public.leveraged_positions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  asset_id          uuid not null references public.assets (id),
  side              text not null check (side in ('long', 'short')),
  leverage          int  not null check (leverage in (5, 10, 50, 100)),
  quantity          numeric(18,4) not null check (quantity > 0),
  entry_price       numeric(18,4) not null check (entry_price > 0),
  margin            numeric(18,2) not null check (margin > 0),
  liquidation_price numeric(18,4) not null,
  take_profit       numeric(18,4) check (take_profit is null or take_profit > 0),
  stop_loss         numeric(18,4) check (stop_loss is null or stop_loss > 0),
  status            text not null default 'open'
                      check (status in ('open', 'closed', 'liquidated')),
  close_price       numeric(18,4),
  realized_pnl      numeric(18,2),
  close_reason      text check (close_reason in
                      ('manual', 'take_profit', 'stop_loss', 'liquidation')),
  opened_at         timestamptz not null default now(),
  closed_at         timestamptz
);

create index leveraged_positions_user_idx on public.leveraged_positions (user_id, opened_at desc);
create index leveraged_positions_open_idx on public.leveraged_positions (asset_id) where status = 'open';

alter table public.leveraged_positions enable row level security;
create policy "own leveraged positions" on public.leveraged_positions for select
  using (user_id = (select auth.uid()));
grant select on public.leveraged_positions to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.leveraged_positions;
  end if;
exception when duplicate_object then null;
end $$;

-- ----------------------------------------------------------------------------
-- Level gating.
-- ----------------------------------------------------------------------------
create or replace function game.max_leverage_for_level(p_level int)
returns int
language sql
immutable
as $$
  select case when p_level >= 10 then 100
              when p_level >= 5  then 50
              else 10 end;
$$;

-- ----------------------------------------------------------------------------
-- Open a leveraged position. Sized by margin: qty = margin·leverage / entry.
-- ----------------------------------------------------------------------------
create or replace function public.open_leveraged_position(
  p_asset_id uuid,
  p_side     text,
  p_leverage int,
  p_margin   numeric
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
  v_entry    numeric;
  v_qty      numeric;
  v_notional numeric;
  v_liq      numeric;
  v_id       uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_side not in ('long', 'short') then raise exception 'invalid side'; end if;
  if p_leverage not in (5, 10, 50, 100) then raise exception 'invalid leverage'; end if;
  if p_margin is null or p_margin < 100 then
    return jsonb_build_object('status', 'rejected', 'reason', 'minimum margin is $100');
  end if;

  if not game.has_class_unlock(v_user, 'margin') then
    return jsonb_build_object('status', 'rejected', 'reason', 'broker license required');
  end if;

  select * into v_asset from public.assets where id = p_asset_id and is_active
  for update;
  if not found then raise exception 'unknown or inactive asset'; end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if p_leverage > game.max_leverage_for_level(v_profile.level) then
    return jsonb_build_object('status', 'rejected',
      'reason', format('%s× unlocks at level %s', p_leverage,
                       case when p_leverage = 100 then 10 else 5 end));
  end if;
  if v_profile.cash_balance < p_margin then
    return jsonb_build_object('status', 'rejected', 'reason', 'insufficient cash');
  end if;

  v_entry := round(v_asset.current_price *
               (1 + case when p_side = 'long' then 1 else -1 end * v_asset.spread / 2), 4);
  v_qty := round(p_margin * p_leverage / v_entry, 4);
  v_notional := round(v_qty * v_entry, 2);
  if v_notional > game.config_numeric('max_order_notional') then
    return jsonb_build_object('status', 'rejected', 'reason', 'position too large');
  end if;
  v_liq := round(v_entry * (1 + case when p_side = 'long' then -1.0 else 1.0 end
                                / p_leverage), 4);

  insert into public.leveraged_positions
    (user_id, asset_id, side, leverage, quantity, entry_price, margin, liquidation_price)
  values (v_user, p_asset_id, p_side, p_leverage, v_qty, v_entry, p_margin, v_liq)
  returning id into v_id;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'margin_open', -p_margin, 'leveraged_position', v_id::text);

  -- Leveraged flow hits the market at full notional — whales move prices.
  update public.assets
     set flow = flow + case when p_side = 'long' then v_notional else -v_notional end
   where id = p_asset_id;

  update public.profiles
     set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
   where id = v_user;
  perform game.evaluate_missions(v_user);

  return jsonb_build_object('status', 'opened', 'position_id', v_id,
    'entry_price', v_entry, 'quantity', v_qty, 'notional', v_notional,
    'liquidation_price', v_liq, 'max_loss', p_margin);
end;
$$;

-- ----------------------------------------------------------------------------
-- Shared close path (manual, TP, SL, liquidation).
-- realized_pnl is capped at -margin: the loss can never exceed the stake.
-- ----------------------------------------------------------------------------
create or replace function game.close_leveraged_position_internal(
  p_pos    public.leveraged_positions,
  p_exit   numeric,
  p_reason text
)
returns numeric  -- proceeds returned to cash
language plpgsql
as $$
declare
  v_pnl      numeric;
  v_proceeds numeric;
  v_notional numeric := round(p_pos.quantity * p_exit, 2);
begin
  v_pnl := round(case when p_pos.side = 'long'
                      then p_pos.quantity * (p_exit - p_pos.entry_price)
                      else p_pos.quantity * (p_pos.entry_price - p_exit) end, 2);
  v_pnl := greatest(v_pnl, -p_pos.margin);
  v_proceeds := p_pos.margin + v_pnl;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (p_pos.user_id, 'margin_close', v_proceeds, 'leveraged_position',
          p_pos.id::text);

  update public.leveraged_positions
     set status = case when p_reason = 'liquidation' then 'liquidated' else 'closed' end,
         close_price = p_exit,
         realized_pnl = v_pnl,
         close_reason = p_reason,
         closed_at = now()
   where id = p_pos.id;

  -- Closing unwinds the flow the position added.
  update public.assets
     set flow = flow + case when p_pos.side = 'long' then -v_notional else v_notional end
   where id = p_pos.asset_id;

  update public.profiles
     set xp = xp + game.config_numeric('xp_per_trade')::int, updated_at = now()
   where id = p_pos.user_id;

  return v_proceeds;
end;
$$;

create or replace function public.close_leveraged_position(p_position_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user  uuid := auth.uid();
  v_pos   public.leveraged_positions%rowtype;
  v_asset public.assets%rowtype;
  v_exit  numeric;
  v_proceeds numeric;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_pos from public.leveraged_positions
   where id = p_position_id and user_id = v_user and status = 'open'
   for update;
  if not found then raise exception 'no open position to close'; end if;

  select * into v_asset from public.assets where id = v_pos.asset_id for update;
  v_exit := round(v_asset.current_price *
              (1 + case when v_pos.side = 'long' then -1 else 1 end
                   * v_asset.spread / 2), 4);
  v_proceeds := game.close_leveraged_position_internal(v_pos, v_exit, 'manual');
  perform game.evaluate_missions(v_user);
  return jsonb_build_object('status', 'closed', 'exit_price', v_exit,
    'proceeds', v_proceeds,
    'pnl', (select realized_pnl from public.leveraged_positions where id = p_position_id));
end;
$$;

-- ----------------------------------------------------------------------------
-- TP/SL on a leveraged position (stored on the row; tick enforces).
-- ----------------------------------------------------------------------------
create or replace function public.set_leveraged_protection(
  p_position_id uuid,
  p_take_profit numeric default null,
  p_stop_loss   numeric default null
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
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_pos from public.leveraged_positions
   where id = p_position_id and user_id = v_user and status = 'open'
   for update;
  if not found then raise exception 'no open position'; end if;

  select * into v_asset from public.assets where id = v_pos.asset_id;
  v_mark := v_asset.current_price *
              (1 + case when v_pos.side = 'long' then -1 else 1 end
                   * v_asset.spread / 2);

  if v_pos.side = 'long' then
    if p_take_profit is not null and p_take_profit <= v_mark then
      return jsonb_build_object('status', 'rejected',
        'reason', 'take profit must be above the current price');
    end if;
    if p_stop_loss is not null and
       (p_stop_loss >= v_mark or p_stop_loss <= v_pos.liquidation_price) then
      return jsonb_build_object('status', 'rejected',
        'reason', 'stop loss must sit between the liquidation price and the current price');
    end if;
  else
    if p_take_profit is not null and p_take_profit >= v_mark then
      return jsonb_build_object('status', 'rejected',
        'reason', 'take profit must be below the current price');
    end if;
    if p_stop_loss is not null and
       (p_stop_loss <= v_mark or p_stop_loss >= v_pos.liquidation_price) then
      return jsonb_build_object('status', 'rejected',
        'reason', 'stop loss must sit between the current price and the liquidation price');
    end if;
  end if;

  update public.leveraged_positions
     set take_profit = coalesce(round(p_take_profit, 4), take_profit),
         stop_loss   = coalesce(round(p_stop_loss, 4), stop_loss)
   where id = p_position_id;
  return jsonb_build_object('status', 'protected');
end;
$$;

grant execute on function public.open_leveraged_position(uuid, text, int, numeric) to authenticated;
grant execute on function public.close_leveraged_position(uuid) to authenticated;
grant execute on function public.set_leveraged_protection(uuid, numeric, numeric) to authenticated;

-- ----------------------------------------------------------------------------
-- Tick enforcement: liquidations first (they're not optional), then SL/TP.
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
  for v_row in
    select lp.id as pos_id, a.current_price, a.spread
      from public.leveraged_positions lp
      join public.assets a on a.id = lp.asset_id
     where lp.status = 'open'
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
