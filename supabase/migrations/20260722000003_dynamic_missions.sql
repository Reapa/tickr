-- ============================================================================
-- Migration 22: daily / weekly dynamic missions
--
-- Extends the mission engine (migration 11) from a fixed one-time set to a
-- rotating board: a pool of DAILY missions (reset every UTC day) and WEEKLY
-- missions (reset every Monday). Each cycle a fresh random subset is assigned;
-- unfinished missions are cleared on reset ("reset fresh"). Dailies pay cash +
-- XP; weeklies also pay premium gems. Assignment is lazy (on first
-- Missions-screen load via refresh_my_missions) and backstopped by a nightly
-- pg_cron rotation — never at onboarding, so onboarding stays deterministic.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Schema: a cadence on the pool, and per-user cycle bookkeeping.
-- ----------------------------------------------------------------------------
alter table public.missions
  add column cadence text not null default 'permanent'
    check (cadence in ('permanent', 'daily', 'weekly')),
  add column reward_gems int not null default 0 check (reward_gems >= 0);

alter table public.user_missions
  add column cadence     text not null default 'permanent',
  add column period_key  text,          -- 'YYYY-MM-DD' (daily) / 'IYYY-Www' (weekly); null = permanent
  add column assigned_at timestamptz not null default now(),
  add column expires_at  timestamptz;   -- end of this cycle; null = permanent

create index user_missions_cycle_idx
  on public.user_missions (user_id, cadence, period_key);

-- Gems can now also be earned by finishing a weekly. The reason set stays
-- closed and one-directional (no path credits in-game cash), preserving the
-- monetization guarantee from migration 5.
alter table public.premium_ledger drop constraint premium_ledger_reason_check;
alter table public.premium_ledger add constraint premium_ledger_reason_check
  check (reason in ('welcome_grant', 'iap_stub', 'season_reward_bonus',
                    'cosmetic_purchase', 'weekly_mission_bonus'));

-- ----------------------------------------------------------------------------
-- Period helpers. Everything is anchored to UTC; weeks start Monday.
-- ----------------------------------------------------------------------------
create or replace function game.period_key(p_cadence text, p_at timestamptz default now())
returns text language sql immutable as $$
  select case p_cadence
    when 'daily'  then to_char((p_at at time zone 'UTC')::date, 'YYYY-MM-DD')
    when 'weekly' then to_char(p_at at time zone 'UTC', 'IYYY"-W"IW')
    else null end;
$$;

create or replace function game.period_start(p_cadence text, p_at timestamptz default now())
returns timestamptz language sql immutable as $$
  select case p_cadence
    when 'daily'  then (date_trunc('day',  p_at at time zone 'UTC')) at time zone 'UTC'
    when 'weekly' then (date_trunc('week', p_at at time zone 'UTC')) at time zone 'UTC'
    else '-infinity'::timestamptz end;
$$;

create or replace function game.period_end(p_cadence text, p_at timestamptz default now())
returns timestamptz language sql immutable as $$
  select case p_cadence
    when 'daily'  then (date_trunc('day',  p_at at time zone 'UTC') + interval '1 day')  at time zone 'UTC'
    when 'weekly' then (date_trunc('week', p_at at time zone 'UTC') + interval '1 week') at time zone 'UTC'
    else null end;
$$;

-- ----------------------------------------------------------------------------
-- The rotating pool. These live alongside the permanent missions but are only
-- ever surfaced through assignment, never all at once.
-- ----------------------------------------------------------------------------
insert into public.missions (code, title, description, concept, cadence, reward_cash, reward_xp, reward_gems, criteria)
values
  -- Daily
  ('daily_trade_3',    'Active trader',      'Place 3 trades today.',                                  'basics',          'daily', 750,  20, 0, '{"count":3}'),
  ('daily_two_sectors','Spread it around',   'Buy into 2 different sectors today.',                     'diversification', 'daily', 900,  25, 0, '{"sectors":2}'),
  ('daily_sell_profit','Bank a win',         'Sell a position above your average cost today.',          'basics',          'daily', 1000, 30, 0, '{}'),
  ('daily_news_trade', 'Trade the headline', 'Trade an asset while it has live news today.',            'news_reaction',   'daily', 1000, 30, 0, '{}'),
  ('daily_protect',    'Play it safe',       'Set a take-profit or stop-loss today.',                   'risk',            'daily', 800,  25, 0, '{}'),
  -- Weekly (also pay gems)
  ('weekly_trade_20',   'Market regular',    'Place 20 trades this week.',                              'basics',          'weekly', 5000,  120, 15, '{"count":20}'),
  ('weekly_four_sectors','Well diversified', 'Hold positions across 4 different sectors.',              'diversification', 'weekly', 6000,  140, 20, '{"sectors":4}'),
  ('weekly_leverage',   'Leverage lesson',   'Open a leveraged position this week.',                    'risk',            'weekly', 5000,  120, 15, '{}'),
  ('weekly_profit_3',   'Consistent gains',  'Close 3 profitable sells this week.',                     'basics',          'weekly', 7000,  160, 25, '{"count":3}')
on conflict (code) do nothing;

-- ----------------------------------------------------------------------------
-- Assignment: ensure the user holds the CURRENT cycle's set for each cadence.
-- Idempotent within a cycle; on a new cycle it deletes the prior set (reset
-- fresh) and draws a new random subset from the pool.
-- ----------------------------------------------------------------------------
create or replace function game.assign_dynamic_missions(p_user uuid)
returns void
language plpgsql
as $$
declare
  v_cadence text;
  v_count   int;
  v_key     text;
  v_end     timestamptz;
begin
  for v_cadence, v_count in
    select cadence, cnt from (values ('daily', 3), ('weekly', 2)) as v(cadence, cnt)
  loop
    v_key := game.period_key(v_cadence);
    v_end := game.period_end(v_cadence);

    -- Already assigned for this cycle → nothing to do.
    if exists (select 1 from public.user_missions
                where user_id = p_user and cadence = v_cadence and period_key = v_key) then
      continue;
    end if;

    -- Reset fresh: clear any earlier-cycle missions of this cadence.
    delete from public.user_missions
     where user_id = p_user and cadence = v_cadence;

    -- Draw a new random subset from the active pool.
    insert into public.user_missions
      (user_id, mission_id, cadence, period_key, assigned_at, expires_at)
    select p_user, m.id, v_cadence, v_key, now(), v_end
      from public.missions m
     where m.is_active and m.cadence = v_cadence
     order by random()
     limit v_count;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Evaluation: unchanged for permanent missions; adds period-scoped rules for
-- the rotating ones (counts are scoped to the current day/week), skips expired
-- missions, and grants gems on top of cash/XP where a mission carries them.
-- ----------------------------------------------------------------------------
create or replace function game.evaluate_missions(p_user uuid)
returns void
language plpgsql
as $$
declare
  v_um    record;
  v_done  boolean;
  v_since timestamptz;
begin
  for v_um in
    select um.user_id, um.mission_id, um.cadence, um.expires_at,
           m.code, m.criteria, m.reward_cash, m.reward_xp, m.reward_gems
      from public.user_missions um
      join public.missions m on m.id = um.mission_id
     where um.user_id = p_user and um.status = 'active' and m.is_active
       and (um.expires_at is null or um.expires_at > now())
  loop
    -- Rolling missions only count activity inside the current cycle window.
    v_since := game.period_start(v_um.cadence);

    v_done := case v_um.code

      when 'first_trade' then
        exists (select 1 from public.trades where user_id = p_user)

      when 'diversify_3' then
        (select count(distinct a.sector)
           from public.holdings h join public.assets a on a.id = h.asset_id
          where h.user_id = p_user)
        >= coalesce((v_um.criteria ->> 'sectors')::int, 3)

      when 'buy_the_dip' then
        exists (
          select 1
            from public.trades t
            join public.market_events e
              on e.starts_at <= t.created_at
             and t.created_at <= e.starts_at
                   + make_interval(secs => coalesce((v_um.criteria ->> 'window_seconds')::int, 600))
             and e.sentiment = 'negative'
             and (   (e.scope = 'asset' and e.asset_id = t.asset_id)
                  or (e.scope = 'sector' and e.sector =
                        (select sector from public.assets where id = t.asset_id)))
           where t.user_id = p_user and t.side = 'buy')

      when 'earnings_react' then
        exists (
          select 1
            from public.trades t
            join public.market_events e
              on e.asset_id = t.asset_id
             and e.template_code like 'earnings%'
             and t.created_at between e.starts_at and e.ends_at
           where t.user_id = p_user)

      when 'use_leverage' then
        exists (select 1 from public.leveraged_positions where user_id = p_user)

      when 'set_stop_loss' then
        exists (select 1 from public.orders
                 where user_id = p_user and order_type = 'stop')

      when 'take_profit' then
        exists (
          select 1
            from public.trades s
           where s.user_id = p_user and s.side = 'sell'
             and s.price > coalesce((
                   select sum(b.notional) / nullif(sum(b.quantity), 0)
                     from public.trades b
                    where b.user_id = p_user and b.asset_id = s.asset_id
                      and b.side = 'buy' and b.created_at <= s.created_at), 'Infinity'))

      -- ---- Rolling: daily ----
      when 'daily_trade_3' then
        (select count(*) from public.trades
          where user_id = p_user and created_at >= v_since)
        >= coalesce((v_um.criteria ->> 'count')::int, 3)

      when 'daily_two_sectors' then
        (select count(distinct a.sector)
           from public.trades t join public.assets a on a.id = t.asset_id
          where t.user_id = p_user and t.side = 'buy' and t.created_at >= v_since)
        >= coalesce((v_um.criteria ->> 'sectors')::int, 2)

      when 'daily_sell_profit' then
        exists (
          select 1
            from public.trades s
           where s.user_id = p_user and s.side = 'sell' and s.created_at >= v_since
             and s.price > coalesce((
                   select sum(b.notional) / nullif(sum(b.quantity), 0)
                     from public.trades b
                    where b.user_id = p_user and b.asset_id = s.asset_id
                      and b.side = 'buy' and b.created_at <= s.created_at), 'Infinity'))

      when 'daily_news_trade' then
        exists (
          select 1
            from public.trades t
            join public.market_events e on e.asset_id = t.asset_id
           where t.user_id = p_user and t.created_at >= v_since
             and e.scope = 'asset'
             and t.created_at between e.starts_at and e.ends_at)

      when 'daily_protect' then
        exists (select 1 from public.orders
                 where user_id = p_user and side = 'sell' and created_at >= v_since)

      -- ---- Rolling: weekly ----
      when 'weekly_trade_20' then
        (select count(*) from public.trades
          where user_id = p_user and created_at >= v_since)
        >= coalesce((v_um.criteria ->> 'count')::int, 20)

      when 'weekly_four_sectors' then
        (select count(distinct a.sector)
           from public.holdings h join public.assets a on a.id = h.asset_id
          where h.user_id = p_user)
        >= coalesce((v_um.criteria ->> 'sectors')::int, 4)

      when 'weekly_leverage' then
        exists (select 1 from public.leveraged_positions
                 where user_id = p_user and opened_at >= v_since)

      when 'weekly_profit_3' then
        (select count(*)
           from public.trades s
          where s.user_id = p_user and s.side = 'sell' and s.created_at >= v_since
            and s.price > coalesce((
                  select sum(b.notional) / nullif(sum(b.quantity), 0)
                    from public.trades b
                   where b.user_id = p_user and b.asset_id = s.asset_id
                     and b.side = 'buy' and b.created_at <= s.created_at), 'Infinity'))
        >= coalesce((v_um.criteria ->> 'count')::int, 3)

      else false
    end;

    if v_done then
      update public.user_missions
         set status = 'completed', completed_at = now()
       where user_id = v_um.user_id and mission_id = v_um.mission_id;

      if v_um.reward_cash > 0 then
        insert into public.transactions (user_id, type, cash_delta, ref_type, ref_id)
        values (p_user, 'mission_reward', v_um.reward_cash, 'mission', v_um.code);
      end if;
      if v_um.reward_xp > 0 then
        update public.profiles set xp = xp + v_um.reward_xp, updated_at = now()
         where id = p_user;
      end if;
      if v_um.reward_gems > 0 then
        insert into public.premium_ledger (user_id, delta, reason)
        values (p_user, v_um.reward_gems, 'weekly_mission_bonus');
      end if;
    end if;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Player RPC: refresh my board (assign the current cycle, then re-evaluate so
-- freshly-assigned missions already reflect activity done this cycle). Called
-- by the missions screen on load.
-- ----------------------------------------------------------------------------
create or replace function public.refresh_my_missions()
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  perform game.assign_dynamic_missions(v_user);
  perform game.evaluate_missions(v_user);
end;
$$;

grant execute on function public.refresh_my_missions() to authenticated;

-- ----------------------------------------------------------------------------
-- Onboarding: enroll the permanent missions and seed an initial rotating set.
-- (Redefines migration 7's trigger function with the mission block updated.)
-- ----------------------------------------------------------------------------
create or replace function game.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_name    text;
  v_code    text;
  v_cash    numeric := game.config_numeric('starting_cash');
  v_premium int     := game.config_numeric('starting_premium')::int;
  v_season  public.seasons%rowtype;
begin
  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    split_part(coalesce(new.email, 'trader'), '@', 1)
  );
  v_name := left(v_name, 20);
  if char_length(v_name) < 2 then
    v_name := 'Trader';
  end if;

  if exists (select 1 from public.profiles where lower(display_name) = lower(v_name)) then
    v_name := left(v_name, 14) || '-' || substr(md5(new.id::text), 1, 4);
  end if;
  loop
    v_code := game.generate_friend_code();
    exit when not exists (select 1 from public.profiles where friend_code = v_code);
  end loop;

  insert into public.profiles (id, display_name, friend_code, net_worth)
  values (new.id, v_name, v_code, v_cash);

  insert into public.transactions (user_id, type, cash_delta, ref_type)
  values (new.id, 'starting_grant', v_cash, 'onboarding');

  insert into public.premium_ledger (user_id, delta, reason)
  values (new.id, v_premium, 'welcome_grant');

  insert into public.user_asset_class_unlocks (user_id, class_id)
  values (new.id, 'stocks');

  -- Only the permanent milestones are enrolled up front. The rotating daily /
  -- weekly board is drawn lazily on first Missions-screen load
  -- (refresh_my_missions) and by the nightly rotation, so onboarding stays lean
  -- and deterministic.
  insert into public.user_missions (user_id, mission_id, cadence)
  select new.id, m.id, 'permanent'
    from public.missions m
   where m.is_active and m.cadence = 'permanent';

  select * into v_season
    from public.seasons
   where status = 'active' and now() between starts_at and ends_at
   order by number desc limit 1;
  if found then
    insert into public.season_scores
      (season_id, user_id, starting_net_worth, current_net_worth)
    values (v_season.id, new.id, v_cash, v_cash);
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- Backfill: give every existing player their first rotating board.
-- ----------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select id from public.profiles loop
    perform game.assign_dynamic_missions(r.id);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- Nightly rotation backstop. A single 00:05 UTC job resets each active player's
-- board; assign_dynamic_missions is a no-op when the cycle hasn't turned, so
-- one daily run also handles the Monday weekly reset. Lazy on-read assignment
-- covers everyone else.
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'rotate-dynamic-missions',
      '5 0 * * *',
      $cron$
        select game.assign_dynamic_missions(p.id)
          from public.profiles p
         where exists (select 1 from public.transactions t
                        where t.user_id = p.id
                          and t.created_at > now() - interval '14 days');
      $cron$
    );
  else
    raise notice 'pg_cron missing: rotate dynamic missions externally.';
  end if;
end $$;
