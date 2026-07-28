-- ============================================================================
-- Leveraged closes were invisible in the activity feeds
--
-- Reported: "leverage doesn't display profit realized in portfolio and the
-- compete windows, seems like it is a separate system to the buy and sell".
--
-- It literally is. A spot trade writes `orders` (+ realized_pnl, stamped by
-- migration 20260722000011); a leveraged close writes `leveraged_positions`
-- and never touches `orders`. So:
--
--   * Portfolio "Recent orders" reads public.orders directly -> leveraged
--     closes never appeared at all, win or lose.
--   * Compete's live feed unioned leveraged OPENS only, with a hardcoded
--     null realized_pnl -> you saw someone enter a 50x long and then never
--     saw how it ended.
--
-- Rather than back-fill leveraged trades into `orders` (they have no order
-- lifecycle — no quantity-to-fill, no reject reason, no trigger), both feeds
-- now read a union that presents the two systems in one shape.
--
-- Return basis differs by design and the client labels it: a spot close
-- returns on cost basis, a leveraged close returns on the MARGIN staked —
-- which is the number that actually matters at 50x.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Your own recent activity: spot orders + leveraged opens/closes.
-- ----------------------------------------------------------------------------
drop function if exists public.get_my_recent_trades(int);

create or replace function public.get_my_recent_trades(p_limit int default 20)
returns table (
  at            timestamptz,
  asset_id      uuid,
  kind          text,        -- 'spot' | 'leverage'
  side          text,        -- buy/sell | long/short
  quantity      numeric,
  status        text,        -- filled | rejected | pending | open | closed | liquidated
  reject_reason text,
  realized_pnl  numeric,
  cost_basis    numeric,     -- spot: avg cost/unit. leverage: margin staked.
  xp_multiplier int,
  leverage      int,
  close_reason  text
)
language sql
stable
security definer
set search_path = public, game
as $$
  select * from (
    -- The derived table takes its column names from this first branch, and
    -- the ORDER BY below references `at`.
    select o.created_at as at, o.asset_id, 'spot'::text as kind, o.side,
           o.quantity, o.status, o.reject_reason, o.realized_pnl,
           o.close_avg_cost as cost_basis, o.xp_multiplier,
           null::int as leverage, null::text as close_reason
      from public.orders o
     where o.user_id = auth.uid()
    union all
    -- A closed position is dated by its close, an open one by its open, so the
    -- feed reads chronologically the way the player experienced it.
    select coalesce(lp.closed_at, lp.opened_at), lp.asset_id, 'leverage'::text,
           lp.side, lp.quantity, lp.status, null::text, lp.realized_pnl,
           lp.margin, null::int, lp.leverage, lp.close_reason
      from public.leveraged_positions lp
     where lp.user_id = auth.uid()
  ) feed
  order by at desc
  limit least(greatest(p_limit, 1), 100);
$$;

grant execute on function public.get_my_recent_trades(int) to authenticated;

comment on function public.get_my_recent_trades(int) is
  'Unified personal activity feed. Spot orders and leveraged positions are '
  'stored in separate systems; this presents them in one shape so realized P/L '
  'shows for both. cost_basis is per-unit avg cost for spot, margin staked for '
  'leverage.';

-- ----------------------------------------------------------------------------
-- 2. The public Compete feed: show how leveraged bets ENDED, not just that
--    they were placed. Redefined from 20260722000011_realized_pnl.sql; the
--    only change is the third union branch for closes.
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
    union all
    -- The payoff. A liquidation is the most dramatic thing that happens in
    -- this game and it was never once shown to anybody.
    select lp.closed_at, p.display_name, a.symbol,
           case when lp.status = 'liquidated' then 'liquidation' else 'leverage_close' end,
           lp.side, lp.margin * lp.leverage, lp.leverage, lp.realized_pnl
      from public.leveraged_positions lp
      join public.assets a on a.id = lp.asset_id
      join public.profiles p on p.id = lp.user_id
     where lp.status in ('closed', 'liquidated') and lp.closed_at is not null
  ) feed
  order by at desc
  limit least(greatest(p_limit, 1), 100);
$$;

grant execute on function public.get_recent_activity(int) to authenticated;
