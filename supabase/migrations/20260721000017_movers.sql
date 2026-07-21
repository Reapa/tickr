-- ============================================================================
-- Migration 17: top movers feed for the market screen
--
-- Biggest gainers/losers over a window, computed in one query (current price
-- vs the oldest tick inside the window). Public data only; security invoker so
-- RLS applies. Powers the "Top Movers" strip.
-- ============================================================================

create or replace function public.get_movers(p_window_hours int default 24)
returns table (
  asset_id     uuid,
  symbol       text,
  name         text,
  current_price numeric,
  change_pct   numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  select a.id, a.symbol, a.name, a.current_price,
         round(100 * (a.current_price / nullif(o.open_price, 0) - 1), 2) as change_pct
    from public.assets a
    join lateral (
      select p.price as open_price
        from public.price_ticks p
       where p.asset_id = a.id
         and p.tick_at >= now() - make_interval(hours => greatest(p_window_hours, 1))
       order by p.tick_at asc
       limit 1
    ) o on true
   where a.is_active
   order by abs(a.current_price / nullif(o.open_price, 0) - 1) desc nulls last;
$$;

grant execute on function public.get_movers(int) to anon, authenticated;
