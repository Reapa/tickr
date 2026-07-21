-- ============================================================================
-- Migration 4: orders, trades, the append-only transactions ledger, holdings
--
-- Invariant: profiles.cash_balance == SUM(transactions.cash_delta) per user,
-- and holdings == aggregated qty_delta per (user, asset). Both are maintained
-- by the game.apply_transaction() trigger and checked by
-- game.reconcile_ledger() (under pgTAP test).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- orders: player intents. v1 fills market orders instantly; the order_type /
-- limit_price / status columns are the seam for limit orders and a future CLOB.
-- ----------------------------------------------------------------------------
create table public.orders (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  asset_id      uuid not null references public.assets (id),
  side          text not null check (side in ('buy', 'sell')),
  order_type    text not null default 'market' check (order_type in ('market', 'limit')),
  quantity      numeric(18,4) not null check (quantity > 0),
  limit_price   numeric(18,4) check (limit_price is null or limit_price > 0),
  status        text not null check (status in ('pending', 'filled', 'rejected', 'cancelled')),
  reject_reason text,
  created_at    timestamptz not null default now(),
  filled_at     timestamptz,
  check (order_type <> 'limit' or limit_price is not null)
);

create index orders_user_idx on public.orders (user_id, created_at desc);

-- ----------------------------------------------------------------------------
-- trades: executed fills.
-- ----------------------------------------------------------------------------
create table public.trades (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders (id),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  asset_id   uuid not null references public.assets (id),
  side       text not null check (side in ('buy', 'sell')),
  quantity   numeric(18,4) not null check (quantity > 0),
  price      numeric(18,4) not null check (price > 0),
  notional   numeric(18,2) not null,
  created_at timestamptz not null default now()
);

create index trades_user_idx  on public.trades (user_id, created_at desc);
create index trades_asset_idx on public.trades (asset_id, created_at desc);

-- ----------------------------------------------------------------------------
-- transactions: THE append-only cash + holdings ledger. Every economy change
-- is a row here. The closed CHECK set on type is a monetization guarantee:
-- there is deliberately no member that credits cash from premium currency.
-- ----------------------------------------------------------------------------
create table public.transactions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  type       text not null check (type in (
               'starting_grant',    -- signup cash
               'trade_buy',         -- cash out, asset in
               'trade_sell',        -- asset out, cash in
               'class_unlock',      -- cash out, progression in
               'mission_reward',    -- cash in
               'challenge_reward',  -- cash in
               'season_reward'      -- cash in
             )),
  cash_delta numeric(18,2) not null,
  asset_id   uuid references public.assets (id),
  qty_delta  numeric(18,4) not null default 0,
  ref_type   text,   -- 'trade' | 'mission' | 'challenge' | 'season' | 'class'
  ref_id     text,
  created_at timestamptz not null default now(),
  -- shape constraints: trades must move an asset; pure-cash types must not
  check (type not in ('trade_buy', 'trade_sell') or (asset_id is not null and qty_delta <> 0)),
  check (type in  ('trade_buy', 'trade_sell') or qty_delta = 0),
  check (type <> 'trade_buy'  or (cash_delta < 0 and qty_delta > 0)),
  check (type <> 'trade_sell' or (cash_delta > 0 and qty_delta < 0)),
  check (type <> 'class_unlock' or cash_delta <= 0),
  check (type not in ('starting_grant', 'mission_reward', 'challenge_reward', 'season_reward') or cash_delta >= 0)
);

create index transactions_user_idx on public.transactions (user_id, created_at desc);
create index transactions_user_asset_idx on public.transactions (user_id, asset_id) where asset_id is not null;

create trigger transactions_append_only
  before update or delete on public.transactions
  for each row execute function game.forbid_mutation();

-- ----------------------------------------------------------------------------
-- holdings: current positions, trigger-materialized from the ledger.
-- avg_cost uses the weighted-average method and only changes on buys.
-- ----------------------------------------------------------------------------
create table public.holdings (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  asset_id   uuid not null references public.assets (id),
  quantity   numeric(18,4) not null check (quantity > 0),
  avg_cost   numeric(18,4) not null check (avg_cost >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, asset_id)
);

create index holdings_asset_idx on public.holdings (asset_id);

-- ----------------------------------------------------------------------------
-- Ledger application trigger: the ONLY code path that touches cash_balance
-- and holdings. Inserting a ledger row atomically applies it.
-- ----------------------------------------------------------------------------
create or replace function game.apply_transaction()
returns trigger
language plpgsql
as $$
declare
  v_price   numeric;
  v_holding public.holdings%rowtype;
begin
  -- Cash: the profiles CHECK (cash_balance >= 0) makes overdrafts impossible
  -- even if a caller forgets to validate.
  update public.profiles
     set cash_balance = cash_balance + new.cash_delta,
         updated_at   = now()
   where id = new.user_id;

  if not found then
    raise exception 'ledger row for unknown profile %', new.user_id;
  end if;

  -- Holdings
  if new.qty_delta > 0 then
    v_price := abs(new.cash_delta) / new.qty_delta;  -- effective fill price
    insert into public.holdings as h (user_id, asset_id, quantity, avg_cost)
    values (new.user_id, new.asset_id, new.qty_delta, v_price)
    on conflict (user_id, asset_id) do update
      set avg_cost = ((h.quantity * h.avg_cost) + (excluded.quantity * excluded.avg_cost))
                     / (h.quantity + excluded.quantity),
          quantity = h.quantity + excluded.quantity,
          updated_at = now();
  elsif new.qty_delta < 0 then
    select * into v_holding
      from public.holdings
     where user_id = new.user_id and asset_id = new.asset_id
     for update;
    if not found or v_holding.quantity < -new.qty_delta then
      raise exception 'insufficient holdings: have %, selling %',
        coalesce(v_holding.quantity, 0), -new.qty_delta;
    end if;
    if v_holding.quantity = -new.qty_delta then
      delete from public.holdings
       where user_id = new.user_id and asset_id = new.asset_id;
    else
      update public.holdings
         set quantity = quantity + new.qty_delta,
             updated_at = now()
       where user_id = new.user_id and asset_id = new.asset_id;
    end if;
  end if;

  return new;
end;
$$;

create trigger transactions_apply
  after insert on public.transactions
  for each row execute function game.apply_transaction();

-- ----------------------------------------------------------------------------
-- Reconciliation: asserts the derived state matches the ledger. Returns
-- offending user_ids; healthy systems return zero rows.
-- ----------------------------------------------------------------------------
create or replace function game.reconcile_ledger()
returns table (user_id uuid, problem text, expected numeric, actual numeric)
language sql
stable
as $$
  -- cash drift
  select p.id, 'cash_balance', coalesce(t.total, 0), p.cash_balance
    from public.profiles p
    left join (
      select transactions.user_id as uid, sum(cash_delta) as total
        from public.transactions group by 1
    ) t on t.uid = p.id
   where p.cash_balance <> coalesce(t.total, 0)
  union all
  -- holdings drift (includes phantom or missing positions)
  select coalesce(h.user_id, l.uid), 'holdings:' || coalesce(h.asset_id, l.aid)::text,
         coalesce(l.total, 0), coalesce(h.quantity, 0)
    from public.holdings h
    full outer join (
      select transactions.user_id as uid, asset_id as aid, sum(qty_delta) as total
        from public.transactions
       where asset_id is not null
       group by 1, 2
      having sum(qty_delta) <> 0
    ) l on l.uid = h.user_id and l.aid = h.asset_id
   where coalesce(h.quantity, 0) <> coalesce(l.total, 0);
$$;
