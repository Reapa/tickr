-- ============================================================================
-- Migration 27: expose equipped cosmetics on the friends + season boards
--
-- The global `leaderboard` view already carries `equipped`; add it to the
-- season view and the friends RPC so avatar frames / badges render on every
-- leaderboard, not just the global one.
-- ============================================================================

-- Appended as the last column (CREATE OR REPLACE VIEW requires additions only).
create or replace view public.season_leaderboard
  with (security_invoker = true) as
  select s.season_id,
         s.user_id,
         p.display_name,
         p.level,
         s.pct_return,
         s.current_net_worth,
         rank() over (partition by s.season_id
                      order by s.pct_return desc, s.joined_at asc) as rank,
         p.equipped
    from public.season_scores s
    join public.profiles p on p.id = s.user_id;

-- Return type changes, so drop + recreate.
drop function if exists public.get_friends_leaderboard();
create function public.get_friends_leaderboard()
returns table (user_id uuid, display_name text, net_worth numeric, level int,
               rank bigint, equipped jsonb)
language sql
stable
security invoker
set search_path = public
as $$
  with friend_ids as (
    select case when user_a = (select auth.uid()) then user_b else user_a end as fid
      from public.friendships
     where status = 'accepted' and (select auth.uid()) in (user_a, user_b)
    union all
    select (select auth.uid())
  )
  select p.id, p.display_name, p.net_worth, p.level,
         rank() over (order by p.net_worth desc) as rank,
         p.equipped
    from public.profiles p
    join friend_ids f on f.fid = p.id;
$$;

grant execute on function public.get_friends_leaderboard() to authenticated;
