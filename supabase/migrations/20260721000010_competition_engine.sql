-- ============================================================================
-- Migration 10: competition engine
--   - friend requests via friend code (no platform friend-graph dependency)
--   - head-to-head challenges (24h / 7d, ranked by % return)
--   - season scoring, rollover, and cosmetic rewards (called from the tick)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Friends
-- ----------------------------------------------------------------------------
create or replace function public.send_friend_request(p_friend_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user   uuid := auth.uid();
  v_target public.profiles%rowtype;
  v_a uuid; v_b uuid;
  v_existing public.friendships%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_target from public.profiles
   where friend_code = upper(trim(p_friend_code));
  if not found then
    return jsonb_build_object('status', 'rejected', 'reason', 'no player with that friend code');
  end if;
  if v_target.id = v_user then
    return jsonb_build_object('status', 'rejected', 'reason', 'that is your own code');
  end if;

  v_a := least(v_user, v_target.id);
  v_b := greatest(v_user, v_target.id);

  select * into v_existing from public.friendships where user_a = v_a and user_b = v_b;
  if found then
    if v_existing.status = 'accepted' then
      return jsonb_build_object('status', 'rejected', 'reason', 'already friends');
    end if;
    -- Pending request from the other side? Sending back = mutual accept.
    if v_existing.requested_by <> v_user then
      update public.friendships
         set status = 'accepted', responded_at = now()
       where id = v_existing.id;
      return jsonb_build_object('status', 'accepted', 'friend', v_target.display_name);
    end if;
    return jsonb_build_object('status', 'rejected', 'reason', 'request already sent');
  end if;

  insert into public.friendships (user_a, user_b, requested_by)
  values (v_a, v_b, v_user);
  return jsonb_build_object('status', 'pending', 'friend', v_target.display_name);
end;
$$;

create or replace function public.respond_friend_request(p_friendship_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_f    public.friendships%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_f from public.friendships where id = p_friendship_id for update;
  if not found or v_f.status <> 'pending' or v_f.requested_by = v_user
     or v_user not in (v_f.user_a, v_f.user_b) then
    raise exception 'no pending request to respond to';
  end if;
  if p_accept then
    update public.friendships set status = 'accepted', responded_at = now()
     where id = p_friendship_id;
  else
    delete from public.friendships where id = p_friendship_id;
  end if;
end;
$$;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- Friend challenges
-- ----------------------------------------------------------------------------
create or replace function public.create_friend_challenge(p_opponent uuid, p_duration text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_duration not in ('24h', '7d') then raise exception 'invalid duration'; end if;
  if not game.are_friends(v_user, p_opponent) then
    raise exception 'you can only challenge friends';
  end if;
  if exists (select 1 from public.friend_challenges
              where status in ('pending', 'active')
                and least(challenger_id, challengee_id) = least(v_user, p_opponent)
                and greatest(challenger_id, challengee_id) = greatest(v_user, p_opponent)) then
    return jsonb_build_object('status', 'rejected',
                              'reason', 'an open challenge with this friend already exists');
  end if;

  insert into public.friend_challenges (challenger_id, challengee_id, duration)
  values (v_user, p_opponent, p_duration)
  returning id into v_id;
  return jsonb_build_object('status', 'pending', 'challenge_id', v_id);
end;
$$;

create or replace function public.respond_friend_challenge(p_challenge_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_c    public.friend_challenges%rowtype;
  v_len  interval;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_c from public.friend_challenges where id = p_challenge_id for update;
  if not found or v_c.status <> 'pending' or v_c.challengee_id <> v_user then
    raise exception 'no pending challenge to respond to';
  end if;

  if not p_accept then
    update public.friend_challenges set status = 'declined' where id = p_challenge_id;
    return jsonb_build_object('status', 'declined');
  end if;

  v_len := case v_c.duration when '24h' then interval '24 hours' else interval '7 days' end;

  -- Snapshot both net worths at accept time; % return is measured from here.
  update public.friend_challenges
     set status = 'active',
         starts_at = now(),
         ends_at = now() + v_len,
         challenger_start_nw = (select net_worth from public.profiles where id = v_c.challenger_id),
         challengee_start_nw = (select net_worth from public.profiles where id = v_c.challengee_id)
   where id = p_challenge_id;
  return jsonb_build_object('status', 'active', 'ends_at', now() + v_len);
end;
$$;

grant execute on function public.create_friend_challenge(uuid, text) to authenticated;
grant execute on function public.respond_friend_challenge(uuid, boolean) to authenticated;

-- Resolution: called each tick. Also expires stale pending challenges (48h).
create or replace function game.resolve_challenges()
returns void
language plpgsql
as $$
declare
  v_c record;
  v_cr numeric; v_er numeric;
  v_winner uuid;
  v_reward numeric := 500;  -- cash prize for winning a head-to-head
begin
  update public.friend_challenges
     set status = 'expired'
   where status = 'pending' and created_at < now() - interval '48 hours';

  for v_c in
    select * from public.friend_challenges
     where status = 'active' and ends_at <= now()
     for update
  loop
    v_cr := (select net_worth from public.profiles where id = v_c.challenger_id)
              / nullif(v_c.challenger_start_nw, 0) - 1;
    v_er := (select net_worth from public.profiles where id = v_c.challengee_id)
              / nullif(v_c.challengee_start_nw, 0) - 1;
    v_winner := case
      when v_cr > v_er then v_c.challenger_id
      when v_er > v_cr then v_c.challengee_id
      else null  -- tie
    end;

    update public.friend_challenges
       set status = 'completed',
           challenger_return = round(coalesce(v_cr, 0), 6),
           challengee_return = round(coalesce(v_er, 0), 6),
           winner_id = v_winner
     where id = v_c.id;

    if v_winner is not null then
      insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
      values (v_winner, 'challenge_reward', v_reward, 'challenge', v_c.id::text);
    end if;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Seasons
-- ----------------------------------------------------------------------------

-- Tick upkeep: enroll any profile not yet in the active season, then refresh
-- current net worth / % return for everyone enrolled.
create or replace function game.update_season_scores()
returns void
language plpgsql
as $$
declare
  v_season public.seasons%rowtype;
begin
  select * into v_season from public.seasons
   where status = 'active' and now() between starts_at and ends_at
   order by number desc limit 1;
  if not found then return; end if;

  insert into public.season_scores (season_id, user_id, starting_net_worth, current_net_worth)
  select v_season.id, p.id, greatest(p.net_worth, 1), p.net_worth
    from public.profiles p
   where not exists (select 1 from public.season_scores s
                      where s.season_id = v_season.id and s.user_id = p.id);

  update public.season_scores s
     set current_net_worth = p.net_worth,
         pct_return = round(p.net_worth / nullif(s.starting_net_worth, 0) - 1, 6)
    from public.profiles p
   where p.id = s.user_id and s.season_id = v_season.id;
end;
$$;

-- Close ended seasons: freeze ranks, grant cosmetic + premium rewards to the
-- top 10%, cash prize to top 3, then open the next season.
create or replace function game.resolve_seasons()
returns void
language plpgsql
as $$
declare
  v_s public.seasons%rowtype;
  v_cosmetic public.cosmetics%rowtype;
  v_players int;
  v_cutoff int;
  v_len numeric := game.config_numeric('season_length_days');
begin
  for v_s in
    select * from public.seasons where status = 'active' and ends_at <= now()
    for update
  loop
    update public.season_scores s
       set final_rank = r.rnk
      from (select user_id, rank() over (order by pct_return desc, joined_at asc) as rnk
              from public.season_scores where season_id = v_s.id) r
     where r.user_id = s.user_id and s.season_id = v_s.id;

    select count(*) into v_players from public.season_scores where season_id = v_s.id;
    v_cutoff := greatest(1, ceil(v_players * 0.10));

    -- Cosmetic for the top 10%.
    if v_s.reward_cosmetic_code is not null then
      select * into v_cosmetic from public.cosmetics where code = v_s.reward_cosmetic_code;
      if found then
        insert into public.user_cosmetics (user_id, cosmetic_id, acquired_via)
        select s.user_id, v_cosmetic.id, 'season_reward'
          from public.season_scores s
         where s.season_id = v_s.id and s.final_rank <= v_cutoff
        on conflict do nothing;
      end if;
    end if;

    -- Premium bonus for the top 10%, cash prize for the podium.
    insert into public.premium_ledger (user_id, delta, reason)
    select s.user_id, 100, 'season_reward_bonus'
      from public.season_scores s
     where s.season_id = v_s.id and s.final_rank <= v_cutoff;

    insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
    select s.user_id,
           'season_reward',
           case s.final_rank when 1 then 5000 when 2 then 2500 else 1000 end,
           'season', v_s.id::text
      from public.season_scores s
     where s.season_id = v_s.id and s.final_rank <= 3;

    update public.seasons set status = 'closed' where id = v_s.id;

    insert into public.seasons (number, name, starts_at, ends_at, reward_cosmetic_code)
    values (v_s.number + 1,
            'Season ' || (v_s.number + 1),
            now(),
            now() + make_interval(days => v_len::int),
            v_s.reward_cosmetic_code);
  end loop;
end;
$$;
