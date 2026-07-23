-- ============================================================================
-- Migration 34: reward crates (variable-reward loot, cosmetics + XP only)
--
-- Rewards become crates with weighted rarity tables — the reveal is the reward
-- moment. Strictly cosmetics + XP, so the schema-enforced no-pay-to-win pledge
-- stays intact (crates never touch cash or premium currency).
--
-- Tiers: common / rare / legendary. Opening rolls (server-side, ungameable)
-- either an unowned cosmetic (rarity weighted by tier) or an XP bundle; if the
-- player already owns every eligible cosmetic, it falls back to XP.
--
-- Sources wired here: a daily-streak milestone (every 7th day, tier escalating),
-- a welcome crate for every new player (trigger) + a backfill for existing ones.
-- ============================================================================

create table public.user_crates (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  tier               text not null check (tier in ('common', 'rare', 'legendary')),
  source             text not null,               -- streak | welcome | ...
  opened             boolean not null default false,
  granted_at         timestamptz not null default now(),
  opened_at          timestamptz,
  reward_kind        text check (reward_kind in ('xp', 'cosmetic')),
  reward_xp          int,
  reward_cosmetic_id uuid references public.cosmetics (id)
);

create index user_crates_user_idx on public.user_crates (user_id, opened, granted_at desc);

alter table public.user_crates enable row level security;
grant select on public.user_crates to authenticated;
create policy "own crates" on public.user_crates for select
  using (user_id = (select auth.uid()));

-- Live: a granted crate should pop into the player's inventory immediately.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_crates;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Grant a crate (internal; called by streak/onboarding/etc.).
-- ----------------------------------------------------------------------------
create or replace function game.grant_crate(p_user uuid, p_tier text, p_source text)
returns uuid
language plpgsql
as $$
declare v_id uuid;
begin
  insert into public.user_crates (user_id, tier, source)
  values (p_user, p_tier, p_source)
  returning id into v_id;
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Open a crate: roll the loot, grant it, return what was won.
-- ----------------------------------------------------------------------------
create or replace function public.open_crate(p_crate_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user   uuid := auth.uid();
  v_crate  public.user_crates%rowtype;
  v_p_cos  numeric;   -- chance of a cosmetic (vs XP)
  v_xp_lo  int;
  v_xp_hi  int;
  v_rarity text;
  v_r      numeric := random();
  v_cos    public.cosmetics%rowtype;
  v_xp     int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_crate from public.user_crates
   where id = p_crate_id and user_id = v_user for update;
  if not found then
    return jsonb_build_object('status', 'rejected', 'reason', 'no such crate');
  end if;
  if v_crate.opened then
    return jsonb_build_object('status', 'rejected', 'reason', 'already opened');
  end if;

  -- Tier tuning.
  if v_crate.tier = 'common' then
    v_p_cos := 0.40; v_xp_lo := 80;  v_xp_hi := 180;
    v_rarity := case when v_r < 0.75 then 'common' else 'rare' end;
  elsif v_crate.tier = 'rare' then
    v_p_cos := 0.60; v_xp_lo := 200; v_xp_hi := 550;
    v_rarity := case when v_r < 0.60 then 'rare' when v_r < 0.90 then 'epic' else 'legendary' end;
  else
    v_p_cos := 0.80; v_xp_lo := 500; v_xp_hi := 1500;
    v_rarity := case when v_r < 0.55 then 'epic' else 'legendary' end;
  end if;

  -- Try for a cosmetic: an unowned, non-season item of the rolled rarity, else
  -- any unowned non-season item, else fall back to XP.
  if random() < v_p_cos then
    select c.* into v_cos from public.cosmetics c
     where c.rarity = v_rarity and not c.is_season_reward
       and not exists (select 1 from public.user_cosmetics uc
                        where uc.user_id = v_user and uc.cosmetic_id = c.id)
     order by random() limit 1;
    if not found then
      select c.* into v_cos from public.cosmetics c
       where not c.is_season_reward
         and not exists (select 1 from public.user_cosmetics uc
                          where uc.user_id = v_user and uc.cosmetic_id = c.id)
       order by random() limit 1;
    end if;
  end if;

  if v_cos.id is not null then
    insert into public.user_cosmetics (user_id, cosmetic_id, acquired_via)
    values (v_user, v_cos.id, 'grant');
    update public.user_crates
       set opened = true, opened_at = now(),
           reward_kind = 'cosmetic', reward_cosmetic_id = v_cos.id
     where id = p_crate_id;
    return jsonb_build_object(
      'status', 'opened', 'tier', v_crate.tier, 'kind', 'cosmetic',
      'code', v_cos.code, 'name', v_cos.name,
      'rarity', v_cos.rarity, 'slot', v_cos.slot);
  else
    v_xp := v_xp_lo + floor(random() * (v_xp_hi - v_xp_lo + 1))::int;
    update public.profiles set xp = xp + v_xp, updated_at = now()
     where id = v_user;
    update public.user_crates
       set opened = true, opened_at = now(),
           reward_kind = 'xp', reward_xp = v_xp
     where id = p_crate_id;
    return jsonb_build_object(
      'status', 'opened', 'tier', v_crate.tier, 'kind', 'xp', 'xp', v_xp);
  end if;
end;
$$;

grant execute on function public.open_crate(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- New players get a welcome crate. A trigger on the profile insert keeps the
-- (large) onboarding function untouched.
-- ----------------------------------------------------------------------------
create or replace function game.grant_welcome_crate()
returns trigger
language plpgsql
as $$
begin
  perform game.grant_crate(new.id, 'rare', 'welcome');
  return new;
end;
$$;

create trigger profiles_welcome_crate
  after insert on public.profiles
  for each row execute function game.grant_welcome_crate();

-- ----------------------------------------------------------------------------
-- Streak milestones now also drop a crate (escalating tier). Redefines
-- migration 18's claim_daily_reward, adding the crate grant to the milestone.
-- ----------------------------------------------------------------------------
create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user     uuid := auth.uid();
  v_p        public.profiles%rowtype;
  v_today    date := (now() at time zone 'utc')::date;
  v_streak   int;
  v_reward   numeric;
  v_milestone boolean;
  v_crate_id uuid;
  v_crate_tier text;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  select * into v_p from public.profiles where id = v_user for update;

  if v_p.last_claim_date = v_today then
    return jsonb_build_object('status', 'already_claimed',
                              'streak', v_p.streak_days,
                              'next_reward', game.daily_reward_amount(v_p.streak_days + 1));
  end if;

  if v_p.last_claim_date = v_today - 1 then
    v_streak := v_p.streak_days + 1;
  else
    v_streak := 1;
  end if;
  v_reward := game.daily_reward_amount(v_streak);
  v_milestone := (v_streak % 7 = 0);

  update public.profiles
     set streak_days = v_streak,
         longest_streak = greatest(longest_streak, v_streak),
         last_claim_date = v_today,
         xp = xp + 20,
         updated_at = now()
   where id = v_user;

  insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
  values (v_user, 'daily_reward', v_reward, 'daily', v_today::text);

  -- Milestone drop: a crate whose tier grows with the streak.
  if v_milestone then
    v_crate_tier := case when v_streak >= 28 then 'legendary'
                         when v_streak >= 14 then 'rare'
                         else 'common' end;
    v_crate_id := game.grant_crate(v_user, v_crate_tier, 'streak');
  end if;

  return jsonb_build_object(
    'status', 'claimed',
    'streak', v_streak,
    'reward', v_reward,
    'milestone', v_milestone,
    'crate_tier', v_crate_tier,
    'next_reward', game.daily_reward_amount(v_streak + 1));
end;
$$;

-- ----------------------------------------------------------------------------
-- Backfill: give every existing player one rare welcome crate to open now.
-- ----------------------------------------------------------------------------
insert into public.user_crates (user_id, tier, source)
select id, 'rare', 'welcome' from public.profiles;
