-- ============================================================================
-- Migration 37: season-end drama (results reveal)
--
-- A season closing should feel like a moment. resolve_seasons already stamps
-- season_scores.final_rank and pays out; this adds a one-time "results reveal":
-- claim_season_result() hands the player their final standing + what they won
-- the first time they open the app after a season they were in has closed, then
-- marks it seen. The client shows a reveal card; a final-48h countdown adds
-- late-season pressure (client-side, from the existing season data).
-- ============================================================================

alter table public.season_scores
  add column result_seen boolean not null default false;

-- Existing closed-season results are treated as already seen — the reveal only
-- fires for seasons that close from here on.
update public.season_scores s
   set result_seen = true
  from public.seasons se
 where se.id = s.season_id and se.status = 'closed';

-- ----------------------------------------------------------------------------
-- Return (and acknowledge) the player's most recent unseen closed-season
-- result. Older unseen results are also marked seen so nothing piles up.
-- ----------------------------------------------------------------------------
create or replace function public.claim_season_result()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user   uuid := auth.uid();
  v_r      record;
  v_players int;
  v_cutoff  int;
  v_top10   boolean;
  v_cash    int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select s.season_id, se.number, se.name, se.reward_cosmetic_code,
         s.final_rank, s.pct_return
    into v_r
    from public.season_scores s
    join public.seasons se on se.id = s.season_id
   where s.user_id = v_user and se.status = 'closed'
     and s.result_seen = false and s.final_rank is not null
   order by se.ends_at desc
   limit 1;

  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  -- Acknowledge every unseen closed result so only the latest ever surfaces.
  update public.season_scores s
     set result_seen = true
    from public.seasons se
   where se.id = s.season_id and s.user_id = v_user and se.status = 'closed';

  select count(*) into v_players
    from public.season_scores where season_id = v_r.season_id;
  v_cutoff := greatest(1, ceil(v_players * 0.10));
  v_top10  := v_r.final_rank <= v_cutoff;
  v_cash   := case v_r.final_rank when 1 then 5000 when 2 then 2500
                                  when 3 then 1000 else 0 end;

  return jsonb_build_object(
    'status', 'result',
    'season_number', v_r.number,
    'season_name', v_r.name,
    'rank', v_r.final_rank,
    'players', v_players,
    'pct_return', v_r.pct_return,
    'top10', v_top10,
    'reward_gems', case when v_top10 then 100 else 0 end,
    'reward_cash', v_cash,
    'reward_cosmetic', case when v_top10 then v_r.reward_cosmetic_code end);
end;
$$;

grant execute on function public.claim_season_result() to authenticated;
