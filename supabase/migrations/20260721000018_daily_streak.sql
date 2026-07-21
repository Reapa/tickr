-- ============================================================================
-- Migration 18: daily login streak + reward (retention loop)
--
-- Each UTC day a player can claim a reward once. Consecutive days grow the
-- streak and the payout; a missed day resets it. Weekly milestones (every 7th
-- day) pay a bonus. All cash flows through the ledger like everything else.
-- ============================================================================

alter table public.profiles
  add column streak_days     int  not null default 0,
  add column longest_streak  int  not null default 0,
  add column last_claim_date date;

-- profiles already grants full SELECT to authenticated, so the new columns are
-- readable by the owner. New cash-in ledger type for the reward.
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in (
    'starting_grant', 'trade_buy', 'trade_sell', 'class_unlock',
    'mission_reward', 'challenge_reward', 'season_reward',
    'margin_open', 'margin_close', 'daily_reward'
  ));
alter table public.transactions add constraint transactions_daily_reward_credits
  check (type <> 'daily_reward' or (cash_delta > 0 and qty_delta = 0));

-- Reward schedule: 200 on day 1, +100 per consecutive day (capped 1000),
-- plus a 1000 milestone bonus every 7th day.
create or replace function game.daily_reward_amount(p_streak int)
returns numeric
language sql
immutable
as $$
  select least(200 + (greatest(p_streak, 1) - 1) * 100, 1000)
       + case when p_streak % 7 = 0 then 1000 else 0 end;
$$;

create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user   uuid := auth.uid();
  v_p      public.profiles%rowtype;
  v_today  date := (now() at time zone 'utc')::date;
  v_streak int;
  v_reward numeric;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_p from public.profiles where id = v_user for update;

  if v_p.last_claim_date = v_today then
    return jsonb_build_object('status', 'already_claimed',
                              'streak', v_p.streak_days,
                              'next_reward', game.daily_reward_amount(v_p.streak_days + 1));
  end if;

  -- Consecutive day continues the streak; any gap resets it.
  if v_p.last_claim_date = v_today - 1 then
    v_streak := v_p.streak_days + 1;
  else
    v_streak := 1;
  end if;
  v_reward := game.daily_reward_amount(v_streak);

  update public.profiles
     set streak_days = v_streak,
         longest_streak = greatest(longest_streak, v_streak),
         last_claim_date = v_today,
         xp = xp + 20,
         updated_at = now()
   where id = v_user;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'daily_reward', v_reward, 'daily', v_today::text);

  return jsonb_build_object(
    'status', 'claimed',
    'streak', v_streak,
    'reward', v_reward,
    'milestone', (v_streak % 7 = 0),
    'next_reward', game.daily_reward_amount(v_streak + 1));
end;
$$;

grant execute on function public.claim_daily_reward() to authenticated;
