-- ============================================================================
-- Migration 5: seasons, friend challenges, missions, cosmetics + premium ledger
-- ============================================================================

-- ----------------------------------------------------------------------------
-- seasons: fixed-length competitive periods ranked by % return. Rollover is
-- handled by game.resolve_seasons() from the tick loop.
-- ----------------------------------------------------------------------------
create table public.seasons (
  id         uuid primary key default gen_random_uuid(),
  number     int not null unique,
  name       text not null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  status     text not null default 'active' check (status in ('active', 'closed')),
  reward_cosmetic_code text,   -- cosmetic granted to top finishers on close
  check (ends_at > starts_at)
);

create table public.season_scores (
  season_id          uuid not null references public.seasons (id) on delete cascade,
  user_id            uuid not null references public.profiles (id) on delete cascade,
  starting_net_worth numeric(18,2) not null check (starting_net_worth > 0),
  current_net_worth  numeric(18,2) not null,
  pct_return         numeric(12,6) not null default 0,
  final_rank         int,
  joined_at          timestamptz not null default now(),
  primary key (season_id, user_id)
);

create index season_scores_rank_idx on public.season_scores (season_id, pct_return desc);

-- ----------------------------------------------------------------------------
-- friend_challenges: head-to-head over a fixed window, ranked by % return.
-- Net worths are snapshotted at accept time; resolution runs in the tick loop.
-- ----------------------------------------------------------------------------
create table public.friend_challenges (
  id               uuid primary key default gen_random_uuid(),
  challenger_id    uuid not null references public.profiles (id) on delete cascade,
  challengee_id    uuid not null references public.profiles (id) on delete cascade,
  duration         text not null check (duration in ('24h', '7d')),
  status           text not null default 'pending'
                     check (status in ('pending', 'active', 'declined', 'completed', 'expired')),
  starts_at        timestamptz,
  ends_at          timestamptz,
  challenger_start_nw numeric(18,2),
  challengee_start_nw numeric(18,2),
  challenger_return   numeric(12,6),
  challengee_return   numeric(12,6),
  winner_id        uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  check (challenger_id <> challengee_id)
);

create index friend_challenges_challenger_idx on public.friend_challenges (challenger_id, created_at desc);
create index friend_challenges_challengee_idx on public.friend_challenges (challengee_id, created_at desc);
create index friend_challenges_due_idx on public.friend_challenges (ends_at) where status = 'active';

-- ----------------------------------------------------------------------------
-- missions: the educational layer. Each mission teaches a concept; completion
-- is evaluated server-side (game.evaluate_missions) after trades/ticks, and
-- rewards flow through the transactions ledger like everything else.
-- ----------------------------------------------------------------------------
create table public.missions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  title       text not null,
  description text not null,
  concept     text not null check (concept in
                ('basics', 'diversification', 'news_reaction', 'volatility', 'mean_reversion', 'risk')),
  reward_cash numeric(18,2) not null default 0 check (reward_cash >= 0),
  reward_xp   int not null default 0 check (reward_xp >= 0),
  criteria    jsonb not null default '{}'::jsonb,   -- parameters for the evaluator
  sort_order  int not null default 0,
  is_active   boolean not null default true
);

create table public.user_missions (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  mission_id   uuid not null references public.missions (id) on delete cascade,
  status       text not null default 'active' check (status in ('active', 'completed')),
  progress     jsonb not null default '{}'::jsonb,
  completed_at timestamptz,
  primary key (user_id, mission_id)
);

-- ----------------------------------------------------------------------------
-- cosmetics: strictly visual items. price_premium NULL means not purchasable
-- (season rewards). MONETIZATION GUARANTEE: cosmetics/premium currency never
-- touch the cash ledger — enforced by the closed CHECK sets on
-- transactions.type (migration 4) and premium_ledger.reason (below): neither
-- set contains a member that converts between the two economies.
-- ----------------------------------------------------------------------------
create table public.cosmetics (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  name          text not null,
  description   text not null default '',
  slot          text not null check (slot in ('avatar_frame', 'profile_badge', 'chart_theme', 'ticker_skin')),
  rarity        text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  price_premium int check (price_premium is null or price_premium > 0),
  is_season_reward boolean not null default false,
  check (is_season_reward = false or price_premium is null)  -- season rewards can't be bought
);

create table public.user_cosmetics (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  cosmetic_id  uuid not null references public.cosmetics (id),
  acquired_via text not null check (acquired_via in ('purchase', 'season_reward', 'grant')),
  acquired_at  timestamptz not null default now(),
  primary key (user_id, cosmetic_id)
);

-- ----------------------------------------------------------------------------
-- premium_ledger: append-only ledger for the cosmetic-only currency.
-- The reason CHECK set is closed: currency enters via grants/stub IAP/season
-- bonuses and leaves ONLY via cosmetic purchases. There is no reason that
-- credits in-game cash, and no transactions.type that credits from premium.
-- ----------------------------------------------------------------------------
create table public.premium_ledger (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  delta       int not null check (delta <> 0),
  reason      text not null check (reason in
                ('welcome_grant', 'iap_stub', 'season_reward_bonus', 'cosmetic_purchase')),
  cosmetic_id uuid references public.cosmetics (id),
  created_at  timestamptz not null default now(),
  -- spends must reference the cosmetic bought and be negative; credits positive
  check (reason <> 'cosmetic_purchase' or (delta < 0 and cosmetic_id is not null)),
  check (reason = 'cosmetic_purchase' or delta > 0)
);

create index premium_ledger_user_idx on public.premium_ledger (user_id, created_at desc);

create trigger premium_ledger_append_only
  before update or delete on public.premium_ledger
  for each row execute function game.forbid_mutation();

create or replace function game.apply_premium_transaction()
returns trigger
language plpgsql
as $$
begin
  -- profiles CHECK (premium_balance >= 0) blocks overspends at the DB level.
  update public.profiles
     set premium_balance = premium_balance + new.delta,
         updated_at = now()
   where id = new.user_id;
  if not found then
    raise exception 'premium ledger row for unknown profile %', new.user_id;
  end if;
  return new;
end;
$$;

create trigger premium_ledger_apply
  after insert on public.premium_ledger
  for each row execute function game.apply_premium_transaction();
