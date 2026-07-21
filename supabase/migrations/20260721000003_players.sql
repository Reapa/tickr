-- ============================================================================
-- Migration 3: profiles, class unlocks, friendships
-- ============================================================================

-- ----------------------------------------------------------------------------
-- profiles: one row per player. cash_balance / net_worth / xp are DERIVED —
-- cash_balance is maintained by the transactions-ledger trigger and always
-- equals SUM(transactions.cash_delta); net_worth is refreshed by market_tick().
-- No client can write this table; all changes flow through RPCs.
-- ----------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (char_length(display_name) between 2 and 24),
  friend_code   text not null unique,
  cash_balance  numeric(18,2) not null default 0 check (cash_balance >= 0),
  net_worth     numeric(18,2) not null default 0,
  xp            int not null default 0 check (xp >= 0),
  level         int generated always as ((floor(sqrt(xp / 100.0)))::int + 1) stored,
  premium_balance int not null default 0 check (premium_balance >= 0),
  equipped      jsonb not null default '{}'::jsonb,  -- slot -> cosmetic code
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index profiles_display_name_idx on public.profiles (lower(display_name));
create index profiles_net_worth_idx on public.profiles (net_worth desc);

comment on column public.profiles.cash_balance is
  'Derived from the transactions ledger by trigger. Never mutated directly.';
comment on column public.profiles.premium_balance is
  'Derived from premium_ledger by trigger. Cosmetic-only currency: no schema path converts it to cash.';

-- ----------------------------------------------------------------------------
-- user_asset_class_unlocks: which progression tiers a player has bought into.
-- ----------------------------------------------------------------------------
create table public.user_asset_class_unlocks (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  class_id   text not null references public.asset_classes (id),
  unlocked_at timestamptz not null default now(),
  primary key (user_id, class_id)
);

create or replace function game.has_class_unlock(p_user uuid, p_class text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.user_asset_class_unlocks
    where user_id = p_user and class_id = p_class
  );
$$;

-- ----------------------------------------------------------------------------
-- friendships: friend-code / username based, deliberately independent of any
-- platform friend graph (Google/Facebook do not expose friend lists; Steam is
-- roadmap). Canonical ordering user_a < user_b prevents duplicate pairs.
-- ----------------------------------------------------------------------------
create table public.friendships (
  id           uuid primary key default gen_random_uuid(),
  user_a       uuid not null references public.profiles (id) on delete cascade,
  user_b       uuid not null references public.profiles (id) on delete cascade,
  requested_by uuid not null references public.profiles (id),
  status       text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (user_a < user_b),
  check (requested_by in (user_a, user_b)),
  unique (user_a, user_b)
);

create index friendships_user_a_idx on public.friendships (user_a, status);
create index friendships_user_b_idx on public.friendships (user_b, status);

create or replace function game.are_friends(p_x uuid, p_y uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.friendships
    where user_a = least(p_x, p_y)
      and user_b = greatest(p_x, p_y)
      and status = 'accepted'
  );
$$;
