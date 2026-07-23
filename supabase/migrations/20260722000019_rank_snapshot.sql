-- ============================================================================
-- Migration 38: rank snapshot for leaderboard-overtake notifications
--
-- "Rank movement must never be silent." A tiny read the client polls app-wide:
-- the caller's current global rank plus the display name of whoever now sits
-- one place below them. The client compares against the last poll and toasts
-- "↑ Passed Ryan — now #12" whenever the rank improves. security_invoker so the
-- caller's RLS applies (profiles/leaderboard are player-readable already).
-- ============================================================================

create or replace function public.my_rank_snapshot()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with me as (select rank from public.leaderboard where user_id = auth.uid())
  select jsonb_build_object(
    'rank', (select rank from me),
    'ahead_of', (select display_name from public.leaderboard
                  where rank = (select rank from me) + 1 limit 1));
$$;

grant execute on function public.my_rank_snapshot() to authenticated;
