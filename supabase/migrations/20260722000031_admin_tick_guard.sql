-- ============================================================================
-- Any signed-in player could force market ticks
--
-- public.admin_run_tick() is meant to be service-role only (it exists for the
-- admin-tick edge function, as a fallback when pg_cron is unavailable). Its
-- guard was:
--
--   if coalesce(jwt ->> 'role','') not in ('service_role')
--      and current_user not in ('postgres','supabase_admin') then
--     raise exception 'admin_run_tick is service-role only';
--   end if;
--
-- The function is SECURITY DEFINER, so `current_user` inside it is the function
-- OWNER — always 'postgres' — not the caller. The second half of that AND is
-- therefore permanently false, so the exception could never fire, for anybody.
--
-- Verified: an ordinary authenticated signup calling POST /rpc/admin_run_tick
-- got HTTP 204 and a real tick ran.
--
-- Why it matters beyond tidiness: the tick advances prices, evaluates every
-- stop-loss/take-profit/liquidation, accrues passive income, rolls scheduled
-- events and updates season scores. A player who can call it at will can pump
-- a position, trigger their own resting orders, accelerate income, and hammer
-- the database — one HTTP request per tick, on demand.
--
-- Fix: authorise on the JWT alone, which is the only thing SECURITY DEFINER
-- does not rewrite. Callers with no JWT at all (pg_cron, psql, a direct
-- maintenance session) are internal and still allowed; any caller presenting a
-- JWT must present a service_role one.
-- ============================================================================

create or replace function public.admin_run_tick()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  -- NOTE: deliberately NOT current_user — under SECURITY DEFINER that is the
  -- owner, which is exactly how the original check defeated itself.
  v_claims text := nullif(current_setting('request.jwt.claims', true), '');
  v_role   text := coalesce((v_claims)::jsonb ->> 'role', '');
begin
  -- A request that arrived over the API always carries claims. No claims means
  -- an internal caller (cron / psql), which is trusted.
  if v_claims is not null and v_role <> 'service_role' then
    raise exception 'admin_run_tick is service-role only';
  end if;
  perform game.market_tick();
end;
$$;

revoke execute on function public.admin_run_tick() from public;
revoke execute on function public.admin_run_tick() from anon, authenticated;
grant execute on function public.admin_run_tick() to service_role;
