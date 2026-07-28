-- ============================================================================
-- Idle fishing never caught anything
--
-- `game.accrue_fishing` computed whole fish as
--
--     floor(elapsed_hours * catch_per_hour)
--
-- and then unconditionally set last_accrued_at = now(). The cron runs every 5
-- minutes, so for a rowboat that is floor(0.083 * 2) = 0 fish — and the
-- remainder was thrown away with the clock. Every run reset progress to zero,
-- so the hold never filled. Even the top-tier boat at 10/hour scores
-- floor(0.083 * 10) = 0.
--
-- Verified before the fix by replaying 288 cron runs (24 hours): 0 fish caught
-- against a capacity of 12. The whole idle half of the mini-game was dead in
-- production.
--
-- It passed pgTAP because that test advanced the clock 30 days and called
-- accrue once — a single big gap, which is the ONE path where flooring is
-- harmless. It is not the path production uses. Test 27 now replays the real
-- cron cadence instead.
--
-- Fix: advance the clock only by the time the caught fish actually consumed, so
-- the sub-fish remainder carries to the next run — the same treatment
-- game.refresh_bait already gives partial bait.
--
-- The anti-banking rule is preserved, and it is the reason this needs care
-- rather than just removing the floor: if the hold is full, or filled up part
-- way through the window, the clock still jumps to now(). The boat genuinely
-- stopped fishing, so that time is forfeited and cannot be redeemed later as a
-- windfall. Coming back to empty the hold is the entire point of the loop.
-- ============================================================================

create or replace function game.accrue_fishing(p_user uuid default null)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  r        record;
  v_room   int;
  v_due    int;
  v_take   int;
  i        int;
begin
  if game.config_numeric('fishing_enabled') < 1 then return; end if;

  for r in
    select uf.user_id, uf.last_accrued_at, g.catch_per_hour, g.hold_capacity,
           (select count(*) from public.fishery_hold h where h.user_id = uf.user_id) as held
      from public.user_fishery uf
      join public.fishing_gear g on g.code = uf.boat_code
     where (p_user is null or uf.user_id = p_user)
  loop
    if coalesce(r.catch_per_hour, 0) <= 0 then
      update public.user_fishery
         set last_accrued_at = now(), updated_at = now()
       where user_id = r.user_id;
      continue;
    end if;

    v_room := greatest(r.hold_capacity - r.held, 0);
    v_due  := floor(extract(epoch from now() - r.last_accrued_at) / 3600.0
                    * r.catch_per_hour)::int;
    v_take := least(greatest(v_due, 0), v_room);

    for i in 1 .. v_take loop
      perform game.roll_catch(r.user_id, false);
    end loop;

    if v_room = 0 or v_take < v_due then
      -- The hold was full, or filled up mid-window: the boat idled the rest of
      -- the time and that time is forfeited. No banking a windfall.
      update public.user_fishery
         set last_accrued_at = now(), updated_at = now()
       where user_id = r.user_id;
    else
      -- Advance only by what was actually fished, so the fraction of a fish
      -- left over survives to the next run instead of being rounded away.
      update public.user_fishery
         set last_accrued_at = r.last_accrued_at
                               + make_interval(secs => v_take / r.catch_per_hour * 3600),
             updated_at = now()
       where user_id = r.user_id;
    end if;
  end loop;
end $$;
