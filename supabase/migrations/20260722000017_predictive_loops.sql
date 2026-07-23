-- ============================================================================
-- Migration 36: predictive loops — rumours + prediction micro-bets
--
-- Two "form a thesis, then find out" loops, both server-authoritative and
-- hooked into the existing per-tick event subsystem (schedule_earnings_event /
-- resolve_scheduled_events) so game.market_tick itself is untouched.
--
-- RUMOURS: a directional whisper about an asset that only SOMETIMES resolves
-- into a real event (variable confirmation). If confirmed it moves the price
-- like any news; if not, it fizzles into an "unfounded" note. Teaches players
-- to trade facts, not whispers. Reuses scheduled_events (kind='rumour').
--
-- PREDICTION MICRO-BETS: the game posts a binary call ("Will BTC be higher in
-- 3 min?"). Players pick up/down before it closes; correct callers earn a
-- variable XP payout. Evaluated server-side at the close price.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Rumours ride on scheduled_events with a hidden confirmation chance.
-- ---------------------------------------------------------------------------
alter table public.scheduled_events add column confirm_chance numeric;

insert into public.game_config (key, value, description) values
  ('rumour_share', '0.40',
   'Share of scheduled events that are unconfirmed rumours (vs earnings).')
on conflict (key) do nothing;

create or replace function game.schedule_rumour_event()
returns void
language plpgsql
as $$
declare
  v_asset   public.assets%rowtype;
  v_bull    boolean := random() < 0.5;
  v_impact  numeric;
  v_headline text;
  v_lead    int;
  v_bull_t  text[] := array[
    'Whispers of a takeover bid for {name}',
    'Talk of a blockbuster {name} deal is spreading',
    'Unconfirmed reports: {name} lands a major contract',
    'Chatter about a surprise {name} breakthrough is building'];
  v_bear_t  text[] := array[
    'Rumours swirl of an accounting probe at {name}',
    'Unverified reports of trouble in the {name} boardroom',
    'Speculation of a {name} guidance cut is building',
    'Market chatter warns of {name} supply problems'];
begin
  select a.* into v_asset from public.assets a
   where a.is_active and a.class_id in ('stocks', 'companies', 'crypto')
     and game.is_market_open(a.market_hours)
     and not exists (select 1 from public.scheduled_events se
                      where se.asset_id = a.id and se.status = 'scheduled')
   order by random() limit 1;
  if not found then return; end if;

  if v_bull then
    v_impact := round((0.03 + random() * 0.08)::numeric, 4);
    v_headline := replace(v_bull_t[1 + floor(random() * array_length(v_bull_t, 1))::int],
                          '{name}', v_asset.name);
  else
    v_impact := round((-0.11 + random() * 0.08)::numeric, 4);
    v_headline := replace(v_bear_t[1 + floor(random() * array_length(v_bear_t, 1))::int],
                          '{name}', v_asset.name);
  end if;

  v_lead := 60 + floor(random() * 180)::int;

  insert into public.scheduled_events
    (asset_id, kind, headline, resolves_at, sentiment, fv_impact,
     vol_multiplier, duration_seconds, confirm_chance)
  values
    (v_asset.id, 'rumour', v_headline, now() + make_interval(secs => v_lead),
     case when v_bull then 'positive' else 'negative' end, v_impact,
     round((1.3 + random() * 0.7)::numeric, 4), 1200,
     round((0.40 + random() * 0.25)::numeric, 4));
end;
$$;

-- schedule_earnings_event now sometimes schedules a rumour instead. (Redefines
-- migration 31's version; same earnings logic below the rumour branch.)
create or replace function game.schedule_earnings_event()
returns void
language plpgsql
as $$
declare
  v_asset     public.assets%rowtype;
  v_roll      numeric := random();
  v_sentiment text;
  v_impact    numeric;
  v_quarter   text := 'Q' || (1 + floor(random() * 4))::int;
  v_lead      int;
begin
  if (select count(*) from public.scheduled_events where status = 'scheduled')
       >= game.config_numeric('earnings_max_pending')::int then
    return;
  end if;

  -- Sometimes it's a rumour instead of an earnings announcement.
  if random() < game.config_numeric('rumour_share') then
    perform game.schedule_rumour_event();
    return;
  end if;

  select a.* into v_asset from public.assets a
   where a.is_active and a.class_id in ('stocks', 'companies')
     and game.is_market_open(a.market_hours)
     and not exists (select 1 from public.scheduled_events se
                      where se.asset_id = a.id and se.status = 'scheduled')
   order by random() limit 1;
  if not found then return; end if;

  if v_roll < 0.45 then
    v_sentiment := 'positive';
    v_impact := round((0.03 + random() * 0.09)::numeric, 4);
  elsif v_roll < 0.85 then
    v_sentiment := 'negative';
    v_impact := round((-0.12 + random() * 0.09)::numeric, 4);
  else
    v_sentiment := 'neutral';
    v_impact := round((-0.015 + random() * 0.03)::numeric, 4);
  end if;

  v_lead := 90 + floor(random() * 210)::int;

  insert into public.scheduled_events
    (asset_id, kind, headline, quarter, resolves_at,
     sentiment, fv_impact, vol_multiplier, duration_seconds)
  values
    (v_asset.id, 'earnings',
     v_asset.name || ' (' || v_asset.symbol || ') reports ' || v_quarter || ' earnings',
     v_quarter, now() + make_interval(secs => v_lead),
     v_sentiment, v_impact, round((1.4 + random() * 0.8)::numeric, 4), 1200);
end;
$$;

-- ---------------------------------------------------------------------------
-- Prediction micro-bets.
-- ---------------------------------------------------------------------------
create table public.predictions (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.assets (id) on delete cascade,
  question    text not null,
  opens_at    timestamptz not null default now(),
  closes_at   timestamptz not null,
  open_price  numeric not null,
  close_price numeric,
  result      text check (result in ('up', 'down', 'flat')),
  reward_xp   int not null,
  status      text not null default 'open' check (status in ('open', 'resolved')),
  check (closes_at > opens_at)
);
create index predictions_status_idx on public.predictions (status, closes_at);

create table public.user_predictions (
  prediction_id uuid not null references public.predictions (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  choice        text not null check (choice in ('up', 'down')),
  correct       boolean,
  awarded_xp    int not null default 0,
  created_at    timestamptz not null default now(),
  primary key (prediction_id, user_id)
);

alter table public.predictions      enable row level security;
alter table public.user_predictions enable row level security;
grant select on public.predictions to anon, authenticated;
grant select on public.user_predictions to authenticated;
create policy "predictions readable" on public.predictions for select using (true);
create policy "own predictions" on public.user_predictions for select
  using (user_id = (select auth.uid()));

insert into public.game_config (key, value, description) values
  ('prediction_post_probability', '0.02',
   'Per-tick chance of posting a new prediction micro-bet (under the cap).'),
  ('prediction_max_open', '2', 'Max simultaneously-open prediction micro-bets.'),
  ('prediction_window_seconds', '180', 'How long a prediction stays open.')
on conflict (key) do nothing;

-- Player RPC: make a call on an open prediction (one per prediction).
create or replace function public.make_prediction(p_prediction_id uuid, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_user uuid := auth.uid();
  v_p    public.predictions%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if p_choice not in ('up', 'down') then raise exception 'invalid choice'; end if;

  select * into v_p from public.predictions where id = p_prediction_id;
  if not found then
    return jsonb_build_object('status', 'rejected', 'reason', 'no such prediction');
  end if;
  if v_p.status <> 'open' or now() >= v_p.closes_at then
    return jsonb_build_object('status', 'rejected', 'reason', 'prediction closed');
  end if;
  if exists (select 1 from public.user_predictions
              where prediction_id = p_prediction_id and user_id = v_user) then
    return jsonb_build_object('status', 'rejected', 'reason', 'already answered');
  end if;

  insert into public.user_predictions (prediction_id, user_id, choice)
  values (p_prediction_id, v_user, p_choice);

  return jsonb_build_object('status', 'placed', 'choice', p_choice,
                            'reward_xp', v_p.reward_xp);
end;
$$;

grant execute on function public.make_prediction(uuid, text) to authenticated;

-- Per-tick: resolve due predictions (award correct callers) + maybe post one.
create or replace function game.tick_predictions()
returns void
language plpgsql
as $$
declare
  v_p      record;
  v_result text;
begin
  for v_p in
    select p.id, p.open_price, a.current_price, p.reward_xp
      from public.predictions p
      join public.assets a on a.id = p.asset_id
     where p.status = 'open' and p.closes_at <= now()
     for update of p
  loop
    v_result := case when v_p.current_price > v_p.open_price then 'up'
                     when v_p.current_price < v_p.open_price then 'down'
                     else 'flat' end;

    update public.predictions
       set status = 'resolved', close_price = v_p.current_price, result = v_result
     where id = v_p.id;

    update public.user_predictions up
       set correct = (up.choice = v_result),
           awarded_xp = case when up.choice = v_result then v_p.reward_xp else 0 end
     where up.prediction_id = v_p.id;

    update public.profiles pr
       set xp = pr.xp + v_p.reward_xp, updated_at = now()
     where pr.id in (select user_id from public.user_predictions
                      where prediction_id = v_p.id and choice = v_result);
  end loop;

  -- Post a fresh call occasionally, under the cap.
  if (select count(*) from public.predictions where status = 'open')
       < game.config_numeric('prediction_max_open')::int
     and random() < game.config_numeric('prediction_post_probability') then
    insert into public.predictions (asset_id, question, closes_at, open_price, reward_xp)
    select a.id,
           'Will ' || a.symbol || ' be higher in '
             || (game.config_numeric('prediction_window_seconds') / 60)::int || ' min?',
           now() + make_interval(secs => game.config_numeric('prediction_window_seconds')),
           a.current_price,
           40 + floor(random() * 60)::int
      from public.assets a
     where a.is_active and game.is_market_open(a.market_hours)
       and a.class_id in ('stocks', 'crypto', 'forex')
     order by random() limit 1;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Resolver: handle earnings AND rumours, then drive the prediction tick.
-- (Redefines migration 31's version; earnings branch unchanged.)
-- ---------------------------------------------------------------------------
create or replace function game.resolve_scheduled_events()
returns void
language plpgsql
as $$
declare
  v_se        record;
  v_headline  text;
  v_body      text;
  v_event_id  uuid;
  v_confirmed boolean;
begin
  for v_se in
    select se.*, a.name as asset_name, a.symbol as asset_symbol,
           a.sector as asset_sector, a.market_hours
      from public.scheduled_events se
      join public.assets a on a.id = se.asset_id
     where se.status = 'scheduled' and se.resolves_at <= now()
       and game.is_market_open(a.market_hours)
     order by se.resolves_at
     for update of se
  loop
    if v_se.kind = 'rumour' then
      v_confirmed := random() < coalesce(v_se.confirm_chance, 0.5);
      if v_confirmed then
        v_headline := 'Confirmed: ' || v_se.headline;
        v_body := case when v_se.sentiment = 'positive'
          then 'The whispers around ' || v_se.asset_symbol
               || ' proved true — those who believed them are rewarded.'
          else 'The bad news rumoured about ' || v_se.asset_symbol
               || ' has been confirmed, and the stock reprices.' end;
        insert into public.market_events
          (template_code, scope, asset_id, sector, headline, body, sentiment,
           fv_impact, vol_multiplier, starts_at, ends_at)
        values
          (null, 'asset', v_se.asset_id, v_se.asset_sector, v_headline, v_body,
           v_se.sentiment, v_se.fv_impact, v_se.vol_multiplier,
           now(), now() + make_interval(secs => v_se.duration_seconds))
        returning id into v_event_id;
      else
        v_headline := 'Unfounded: the ' || v_se.asset_symbol || ' rumour came to nothing';
        v_body := 'Speculation about ' || v_se.asset_name
                  || ' fizzled out with no confirmation — a reminder to trade the '
                  || 'facts, not the whispers.';
        insert into public.market_events
          (template_code, scope, asset_id, sector, headline, body, sentiment,
           fv_impact, vol_multiplier, starts_at, ends_at)
        values
          (null, 'asset', v_se.asset_id, v_se.asset_sector, v_headline, v_body,
           'neutral', 0, 1, now(), now() + make_interval(secs => 300))
        returning id into v_event_id;
      end if;
    else
      v_headline := case v_se.sentiment
        when 'positive' then v_se.asset_name || ' smashes ' || v_se.quarter || ' estimates'
        when 'negative' then v_se.asset_name || ' misses ' || v_se.quarter || ' estimates'
        else v_se.asset_name || ' meets ' || v_se.quarter || ' expectations'
      end;
      v_body := case v_se.sentiment
        when 'positive' then v_se.asset_symbol || ' beat expectations on both revenue and '
          || 'guidance — traders who bought the anticipation are being paid.'
        when 'negative' then v_se.asset_symbol || ' came in short of estimates and cut its '
          || 'outlook. The stock reprices lower on the miss.'
        else v_se.asset_symbol || ' landed roughly in line with expectations — a muted '
          || 'reaction as the report held few surprises.'
      end;
      insert into public.market_events
        (template_code, scope, asset_id, sector, headline, body, sentiment,
         fv_impact, vol_multiplier, starts_at, ends_at)
      values
        (null, 'asset', v_se.asset_id, v_se.asset_sector, v_headline, v_body,
         v_se.sentiment, v_se.fv_impact, v_se.vol_multiplier,
         now(), now() + make_interval(secs => v_se.duration_seconds))
      returning id into v_event_id;
    end if;

    update public.scheduled_events
       set status = 'resolved', resolved_event_id = v_event_id
     where id = v_se.id;
  end loop;

  perform game.tick_predictions();
end;
$$;

-- Live updates for both new surfaces.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.predictions;
    alter publication supabase_realtime add table public.user_predictions;
  end if;
end $$;
