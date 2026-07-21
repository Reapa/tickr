-- ============================================================================
-- Migration 13: OHLC candle aggregation for trader-style charts
--
-- Buckets raw price_ticks (5s) into open/high/low/close candles server-side.
-- Clients pick the bucket size (1m/5m/15m/...); raw ticks retain 7 days, so
-- every interval up to 1h has meaningful depth.
-- ============================================================================

create or replace function public.get_candles(
  p_asset_id       uuid,
  p_bucket_seconds int,
  p_limit          int default 60
)
returns table (
  bucket timestamptz,
  open   numeric,
  high   numeric,
  low    numeric,
  close  numeric
)
language sql
stable
set search_path = public
as $$
  select * from (
    select date_bin(make_interval(secs => least(greatest(p_bucket_seconds, 60), 86400)),
                    t.tick_at, timestamptz 'epoch')       as bucket,
           (array_agg(t.price order by t.tick_at asc))[1]  as open,
           max(t.price)                                    as high,
           min(t.price)                                    as low,
           (array_agg(t.price order by t.tick_at desc))[1] as close
      from public.price_ticks t
     where t.asset_id = p_asset_id
     group by 1
     order by 1 desc
     limit least(greatest(coalesce(p_limit, 60), 1), 500)
  ) recent
  order by bucket asc;
$$;

grant execute on function public.get_candles(uuid, int, int) to anon, authenticated;
