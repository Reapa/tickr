-- ============================================================================
-- Migration 19: public activity feed ("big trades")
--
-- A SECURITY DEFINER read that aggregates notable moves across all players —
-- large spot trades and every leveraged open — exposing only public fields
-- (display name, symbol, side, notional, leverage). Trades themselves stay
-- RLS-private; this function is the single, sanitized public window into them,
-- so the market feels populated ("someone just 10× longed Bitcorn").
-- ============================================================================

create or replace function public.get_recent_activity(p_limit int default 30)
returns table (
  at        timestamptz,
  trader    text,
  symbol    text,
  kind      text,
  side      text,
  notional  numeric,
  leverage  int
)
language sql
stable
security definer
set search_path = public
as $$
  select * from (
    select t.created_at as at, p.display_name as trader, a.symbol,
           'spot'::text as kind, t.side, t.notional, null::int as leverage
      from public.trades t
      join public.assets a on a.id = t.asset_id
      join public.profiles p on p.id = t.user_id
     where t.notional >= 1000
    union all
    select lp.opened_at, p.display_name, a.symbol,
           'leverage'::text, lp.side, lp.margin * lp.leverage, lp.leverage
      from public.leveraged_positions lp
      join public.assets a on a.id = lp.asset_id
      join public.profiles p on p.id = lp.user_id
  ) feed
  order by at desc
  limit least(greatest(p_limit, 1), 100);
$$;

grant execute on function public.get_recent_activity(int) to authenticated;
