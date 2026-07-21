-- ============================================================================
-- Migration 6: RLS, column-level grants, leaderboard views, Realtime
--
-- Security model: clients get SELECT-only access. There are NO insert/update/
-- delete policies on any table — every economy write goes through
-- SECURITY DEFINER RPCs (owned by postgres, which owns the tables and thus
-- bypasses RLS). Simulation internals (fair_value, flow, sim params, event
-- impact numbers) are hidden with column-level grants.
-- ============================================================================

-- Enable RLS everywhere.
alter table public.game_config              enable row level security;
alter table public.asset_classes            enable row level security;
alter table public.assets                   enable row level security;
alter table public.price_ticks              enable row level security;
alter table public.event_templates          enable row level security;
alter table public.market_events            enable row level security;
alter table public.profiles                 enable row level security;
alter table public.user_asset_class_unlocks enable row level security;
alter table public.friendships              enable row level security;
alter table public.orders                   enable row level security;
alter table public.trades                   enable row level security;
alter table public.transactions             enable row level security;
alter table public.holdings                 enable row level security;
alter table public.seasons                  enable row level security;
alter table public.season_scores            enable row level security;
alter table public.friend_challenges        enable row level security;
alter table public.missions                 enable row level security;
alter table public.user_missions            enable row level security;
alter table public.cosmetics                enable row level security;
alter table public.user_cosmetics           enable row level security;
alter table public.premium_ledger           enable row level security;

-- Strip the permissive default grants Supabase applies to public-schema
-- objects, then grant back exactly what clients may see.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke usage on schema game from anon, authenticated;

-- Future objects: don't auto-grant to clients; RPC access is granted explicitly.
-- (Postgres grants EXECUTE to PUBLIC on new functions by default — kill that too.)
revoke execute on all functions in schema public from public;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- Public game data: full-row SELECT.
grant select on public.asset_classes, public.price_ticks, public.seasons,
                public.season_scores, public.missions, public.cosmetics,
                public.game_config
  to anon, authenticated;

-- assets: hide fair_value, flow, and all simulation parameters.
grant select (id, symbol, name, class_id, sector, description,
              current_price, spread, is_active, listed_at, updated_at)
  on public.assets to anon, authenticated;

-- market_events: hide the numeric answer key (fv_impact, vol_multiplier);
-- players judge severity from headline + sentiment.
grant select (id, scope, asset_id, sector, headline, body, sentiment,
              starts_at, ends_at)
  on public.market_events to anon, authenticated;

-- profiles: readable by signed-in players (leaderboard is public by design —
-- display name, net worth, level, cosmetics; cash is part of net worth).
grant select on public.profiles to authenticated;

-- Player-private tables.
grant select on public.user_asset_class_unlocks, public.friendships,
                public.orders, public.trades, public.transactions,
                public.holdings, public.friend_challenges,
                public.user_missions, public.user_cosmetics,
                public.premium_ledger
  to authenticated;

-- ---------------------------------------------------------------------------
-- SELECT policies (write policies intentionally absent everywhere).
-- ---------------------------------------------------------------------------
create policy "config readable"          on public.game_config    for select using (true);
create policy "classes readable"         on public.asset_classes  for select using (true);
create policy "assets readable"          on public.assets         for select using (true);
create policy "ticks readable"           on public.price_ticks    for select using (true);
create policy "seasons readable"         on public.seasons        for select using (true);
create policy "season scores readable"   on public.season_scores  for select using (true);
create policy "missions readable"        on public.missions       for select using (is_active);
create policy "cosmetics readable"       on public.cosmetics      for select using (true);

-- News feed: events become visible when they start (no peeking at scheduled news).
create policy "started events readable"  on public.market_events  for select
  using (starts_at <= now());

create policy "profiles readable by players" on public.profiles for select
  to authenticated using (true);

create policy "own unlocks"       on public.user_asset_class_unlocks for select
  using (user_id = (select auth.uid()));
create policy "own orders"        on public.orders        for select using (user_id = (select auth.uid()));
create policy "own trades"        on public.trades        for select using (user_id = (select auth.uid()));
create policy "own transactions"  on public.transactions  for select using (user_id = (select auth.uid()));
create policy "own holdings"      on public.holdings      for select using (user_id = (select auth.uid()));
create policy "own missions"      on public.user_missions  for select using (user_id = (select auth.uid()));
create policy "own cosmetics"     on public.user_cosmetics for select using (user_id = (select auth.uid()));
create policy "own premium ledger" on public.premium_ledger for select using (user_id = (select auth.uid()));

create policy "involved friendships" on public.friendships for select
  using ((select auth.uid()) in (user_a, user_b));
create policy "involved challenges"  on public.friend_challenges for select
  using ((select auth.uid()) in (challenger_id, challengee_id));

-- ---------------------------------------------------------------------------
-- Leaderboard views. security_invoker so the caller's RLS applies.
-- ---------------------------------------------------------------------------
create view public.leaderboard
  with (security_invoker = true) as
  select p.id as user_id,
         p.display_name,
         p.net_worth,
         p.level,
         p.equipped,
         rank() over (order by p.net_worth desc, p.created_at asc) as rank
    from public.profiles p;

create view public.season_leaderboard
  with (security_invoker = true) as
  select s.season_id,
         s.user_id,
         p.display_name,
         p.level,
         s.pct_return,
         s.current_net_worth,
         rank() over (partition by s.season_id
                      order by s.pct_return desc, s.joined_at asc) as rank
    from public.season_scores s
    join public.profiles p on p.id = s.user_id;

grant select on public.leaderboard, public.season_leaderboard to authenticated;

-- Friends-only leaderboard as an RPC (needs auth.uid(), so a view won't do).
create or replace function public.get_friends_leaderboard()
returns table (user_id uuid, display_name text, net_worth numeric, level int, rank bigint)
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
         rank() over (order by p.net_worth desc) as rank
    from public.profiles p
    join friend_ids f on f.fid = p.id;
$$;

grant execute on function public.get_friends_leaderboard() to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: broadcast price ticks, news, profile (net-worth) updates, and
-- social state. Guarded so environments without the publication still migrate.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.price_ticks, public.market_events, public.profiles,
      public.friendships, public.friend_challenges, public.holdings;
  end if;
end $$;
